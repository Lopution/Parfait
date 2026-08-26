import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/account_store.dart';
import '../auth/credential_store.dart';
import '../auth/oauth_service.dart';
import '../auth/token_refresh_gate.dart';
import 'api_error.dart';
import 'pixiv_headers.dart';

/// Cooperative cancellation signal for Pixiv requests.
///
/// Checked before sending, before each retry and while awaiting responses.
/// Cancelling never aborts a token refresh shared with other requests.
class CancelToken {
  final Completer<void> _cancelled = Completer<void>();
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  Future<void> get whenCancel => _cancelled.future;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// Strict, cancellable Pixiv App API client shared by all features.
///
/// - Sends centralized identity headers with the current account's bearer
///   token (read from secure storage per request).
/// - On 401: compares the used token with the stored token and goes through
///   the per-account single-flight [TokenRefreshGate]; each request retries
///   at most once. Invalid refreshes mark the account re-auth-required.
/// - TLS stays strict: transport errors (including certificate failures)
///   surface as [ApiNetworkError] and are never downgraded.
class PixivHttpClient {
  PixivHttpClient({
    http.Client? client,
    required AccountStore accountStore,
    required CredentialStore credentialStore,
    required OAuthService oauthService,
    TokenRefreshGate? refreshGate,
    this.languageTag = 'zh-CN',
    this.requestTimeout = defaultRequestTimeout,
  })  : _client = client ?? http.Client(),
        _accountStore = accountStore,
        _credentialStore = credentialStore,
        _oauthService = oauthService,
        _refreshGate = refreshGate ?? TokenRefreshGate();

  static const Duration defaultRequestTimeout = Duration(seconds: 20);
  static const int maxRetries = 1;

  final http.Client _client;
  final AccountStore _accountStore;
  final CredentialStore _credentialStore;
  final OAuthService _oauthService;
  final TokenRefreshGate _refreshGate;
  final String languageTag;
  final Duration requestTimeout;

  Future<Map<String, dynamic>> getJson(
    Uri uri, {
    CancelToken? cancelToken,
  }) async {
    final response = await get(uri, cancelToken: cancelToken);
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('response is not a JSON object');
      }
      return decoded;
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  Future<http.Response> get(
    Uri uri, {
    CancelToken? cancelToken,
  }) =>
      _send(uri, method: 'GET', cancelToken: cancelToken);

  Future<http.Response> post(
    Uri uri, {
    Map<String, String> body = const {},
    CancelToken? cancelToken,
  }) =>
      _send(uri, method: 'POST', body: body, cancelToken: cancelToken);

  Future<http.Response> _send(
    Uri uri, {
    required String method,
    Map<String, String> body = const {},
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
    var usedToken = await _requireAccessToken();
    http.Response response = await _issue(
      uri,
      method,
      body,
      usedToken,
      cancelToken: cancelToken,
    );

    var retries = 0;
    while (response.statusCode == 401 && retries < maxRetries) {
      final accountId = await _requireCurrentAccountId();
      final storedToken = (await _credentialStore.read(accountId))?.accessToken;
      final outcome = await _refreshGate.refresh(
        accountId: accountId,
        staleToken: usedToken,
        currentToken: storedToken,
        perform: () => _doRefresh(accountId),
      );
      if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
      switch (outcome) {
        case AlreadyRefreshed(:final accessToken):
          usedToken = accessToken;
        case Refreshed(:final accessToken):
          usedToken = accessToken;
        case RefreshFailed():
          await _accountStore.markReauthRequired(accountId);
          throw const ApiUnauthorized('token refresh failed');
      }
      retries += 1;
      response = await _issue(
        uri,
        method,
        body,
        usedToken,
        cancelToken: cancelToken,
      );
    }

    if (response.statusCode == 401) {
      throw const ApiUnauthorized('authentication failed after retry');
    }
    if (response.statusCode == 429) {
      throw ApiRateLimited(_parseRetryAfter(response.headers));
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiHttpError(response.statusCode);
    }
    return response;
  }

  Future<http.Response> _issue(
    Uri uri,
    String method,
    Map<String, String> body,
    String accessToken, {
    CancelToken? cancelToken,
  }) async {
    final request = http.Request(method, uri)
      ..headers.addAll(PixivHeaders.api(
        languageTag: languageTag,
        accessToken: accessToken,
      ));
    if (method == 'POST') {
      request.bodyFields = body;
    }
    final sendFuture = _client
        .send(request)
        .then((streamed) => http.Response.fromStream(streamed));

    final completer = Completer<http.Response>();
    sendFuture.then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );

    final raced = completer.future.timeout(
      requestTimeout,
      onTimeout: () => throw const ApiTimeout(),
    );
    try {
      final winner = await Future.any<dynamic>([
        raced,
        if (cancelToken != null)
          cancelToken.whenCancel
              .then<dynamic>((_) => throw const ApiCancelled()),
      ]);
      return winner as http.Response;
    } on ApiError {
      rethrow;
    } on http.ClientException catch (error) {
      throw ApiNetworkError(error);
    } on SocketException catch (error) {
      throw ApiNetworkError(error);
    } on TlsException catch (error) {
      // Certificate and handshake failures stay failures; never downgraded.
      throw ApiNetworkError(error);
    }
  }

  Future<String> _requireAccessToken() async {
    final context = await _currentContext();
    if (context == null) {
      throw const ApiUnauthorized('no signed-in account');
    }
    return context.accessToken;
  }

  Future<String> _requireCurrentAccountId() async {
    final context = await _currentContext();
    if (context == null) {
      throw const ApiUnauthorized('no signed-in account');
    }
    return context.accountId;
  }

  Future<({String accountId, String accessToken})?> _currentContext() async {
    final state = await _accountStore.resolveState();
    final account = state.usableCurrent;
    if (account == null) return null;
    final credential = await _credentialStore.read(account.id);
    if (credential == null) return null;
    return (accountId: account.id, accessToken: credential.accessToken);
  }

  Future<RefreshOutcome> _doRefresh(String accountId) async {
    try {
      final account = (await _accountStore.resolveState()).usableCurrent;
      if (account == null || account.id != accountId) {
        return const RefreshFailed('account changed during refresh');
      }
      final credential = await _credentialStore.read(accountId);
      if (credential == null) {
        return const RefreshFailed('no stored credential');
      }
      final result = await _oauthService.refreshSession(
        credential.refreshToken,
      );
      await _accountStore.upsertAccount(
        account.copyWith(
          name: result.profile.name,
          mailAddress: result.profile.mailAddress,
          profileImageUrl: result.profile.profileImageUrl,
        ),
        result.credential,
      );
      return Refreshed(result.credential.accessToken);
    } on OAuthException catch (error) {
      return RefreshFailed(error);
    }
  }

  Duration? _parseRetryAfter(Map<String, String> headers) {
    final seconds = int.tryParse(headers['retry-after'] ?? '');
    return seconds == null ? null : Duration(seconds: seconds);
  }
}

final pixivHttpClientProvider = Provider<PixivHttpClient>((ref) {
  return PixivHttpClient(
    accountStore: ref.watch(accountStoreProvider.notifier),
    credentialStore: ref.watch(credentialStoreProvider),
    oauthService: ref.watch(oauthServiceProvider),
  );
});
