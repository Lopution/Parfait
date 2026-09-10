/// Pixiv API transport, authentication refresh, and API error classification.
/// [PixivHttpClient] owns Pixiv requests; policy and client providers own
/// route/client construction. See `backend/directory-structure.md`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/account_store.dart';
import '../auth/credential.dart';
import '../auth/credential_store.dart';
import '../auth/oauth_service.dart';
import '../auth/token_refresh_gate.dart';
import '../settings/settings_controller.dart';
import 'api_error.dart';
import 'compat/network_contracts.dart';
import 'compat/network_providers.dart';
import 'pixiv_headers.dart';

/// Cooperative cancellation signal for Pixiv requests.
///
/// Checked before sending, before each retry and while awaiting responses.
/// Cancelling never aborts a token refresh shared with other requests.
class CancelToken implements NetworkCancelSignal {
  final Completer<void> _cancelled = Completer<void>();
  bool _isCancelled = false;

  @override
  bool get isCancelled => _isCancelled;

  @override
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
/// - Transport selection stays centralized in [NetworkAccessPolicy]. The
///   production fast tier is an internal PixEz-compatible route; strict
///   routes remain available as the policy fallback. Transport errors surface
///   as [ApiNetworkError] and are never hidden.
class PixivHttpClient {
  PixivHttpClient({
    http.Client? client,
    required AccountStore accountStore,
    required CredentialStore credentialStore,
    required OAuthService oauthService,
    TokenRefreshGate? refreshGate,
    this.languageTag = 'zh-CN',
    this.requestTimeout = defaultRequestTimeout,
  }) : _client = client ?? http.Client(),
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
  final Map<_GetRequestFlightKey, Future<http.Response>> _getFlights = {};

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

  /// Reads an App API resource with a caller-supplied credential exactly
  /// once. This is reserved for pre-import verification: it does not use the
  /// current account, refresh, or replay the request, and it never writes the
  /// supplied credential to a store.
  Future<Map<String, dynamic>> getJsonWithCredential(
    Uri uri, {
    required Credential credential,
    CancelToken? cancelToken,
  }) async {
    PixivDestinationRegistry().require(uri, PixivDestinationPurpose.appApi);
    final response = await _issue(
      uri,
      'GET',
      const {},
      credential.accessToken,
      cancelToken: cancelToken,
    );
    if (_isAuthFailure(response)) {
      throw const ApiUnauthorized('supplied credential was rejected');
    }
    if (response.statusCode == 429) {
      throw ApiRateLimited(_parseRetryAfter(response.headers));
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiHttpError(response.statusCode, _errorBodyDetail(response));
    }
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

  Future<http.Response> get(Uri uri, {CancelToken? cancelToken}) =>
      _send(uri, method: 'GET', cancelToken: cancelToken);

  Future<http.Response> post(
    Uri uri, {
    Map<String, String> body = const {},
    CancelToken? cancelToken,

    /// C2: a non-idempotent mutation participates in the single replay
    /// entry point only when it opts in. On an explicit auth rejection
    /// (401, or 400 `invalid_grant`) the credential is refreshed and the
    /// original operation is sent at most once more; timeouts, resets and
    /// unknown outcomes never replay here (the transport ladder does not
    /// replay POSTs either). Nothing is replayed a second time.
    bool allowAuthReplay = false,
  }) => _send(
    uri,
    method: 'POST',
    body: body,
    cancelToken: cancelToken,
    allowAuthReplay: allowAuthReplay,
  );

  Future<http.Response> _send(
    Uri uri, {
    required String method,
    Map<String, String> body = const {},
    CancelToken? cancelToken,
    bool allowAuthReplay = true,
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
    // Pixiv app-api answers an EXPIRED access token with 401 on most
    // endpoints, but some (observed live: /v1/illust/recommended) surface
    // the OAuth "invalid_grant" as 400 instead. Both must trigger the
    // single-flight refresh/retry protocol; other 400 bodies are genuine
    // parameter errors and must not refresh.
    while (_isAuthFailure(response) && retries < maxRetries) {
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
      if (!allowAuthReplay) {
        throw const ApiUnauthorized(
          'authentication refreshed; mutation replay suppressed',
        );
      }
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
    if (_isAuthFailure(response)) {
      // 400 invalid_grant that survived the refresh attempt.
      throw const ApiUnauthorized('oauth invalid_grant after retry');
    }
    if (response.statusCode == 429) {
      throw ApiRateLimited(_parseRetryAfter(response.headers));
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiHttpError(response.statusCode, _errorBodyDetail(response));
    }
    return response;
  }

  /// Short response-body snippet for non-2xx diagnostics. The API error body
  /// is a JSON message (never contains credentials), but it is clamped and
  /// sanitized of control characters before surfacing.
  static String? _errorBodyDetail(http.Response response) {
    try {
      final body = utf8.decode(response.bodyBytes);
      if (body.isEmpty) return null;
      final sanitized = body.replaceAll(RegExp(r'[\x00-\x1f]'), ' ').trim();
      return sanitized.length <= 200
          ? sanitized
          : '${sanitized.substring(0, 200)}…';
    } on FormatException {
      return null;
    }
  }

  /// 401 always; 400 only when the OAuth error body says invalid_grant
  /// (expired token surfaced as 400 by some endpoints).
  static bool _isAuthFailure(http.Response response) {
    if (response.statusCode == 401) return true;
    if (response.statusCode != 400) return false;
    try {
      return utf8.decode(response.bodyBytes).contains('invalid_grant');
    } on FormatException {
      return false;
    }
  }

  /// Shares only uncancelled GETs. A caller with a cancellation token keeps an
  /// independent request so cancelling one view cannot cancel another view's
  /// network work. The key includes the bearer token, preventing a response
  /// from crossing an account/credential boundary during refresh.
  Future<http.Response> _issue(
    Uri uri,
    String method,
    Map<String, String> body,
    String accessToken, {
    CancelToken? cancelToken,
  }) {
    if (method != 'GET' || cancelToken != null) {
      return _issueOnce(
        uri,
        method,
        body,
        accessToken,
        cancelToken: cancelToken,
      );
    }
    final key = _GetRequestFlightKey(uri, accessToken);
    final pending = _getFlights[key];
    if (pending != null) return pending;
    final future = _issueOnce(
      uri,
      method,
      body,
      accessToken,
      cancelToken: cancelToken,
    );
    _getFlights[key] = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_getFlights[key], future)) _getFlights.remove(key);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_getFlights[key], future)) _getFlights.remove(key);
        },
      ),
    );
    return future;
  }

  Future<http.Response> _issueOnce(
    Uri uri,
    String method,
    Map<String, String> body,
    String accessToken, {
    CancelToken? cancelToken,
  }) async {
    final request =
        http.AbortableRequest(
            method,
            uri,
            abortTrigger: cancelToken?.whenCancel,
          )
          ..headers.addAll(
            PixivHeaders.api(
              languageTag: languageTag,
              accessToken: accessToken,
            ),
          );
    if (method == 'POST') {
      request.bodyFields = body;
    }
    final sendFuture = _client
        .send(request)
        .then((streamed) => http.Response.fromStream(streamed));

    final completer = Completer<http.Response>();
    unawaited(
      sendFuture.then(
        (value) {
          if (!completer.isCompleted) completer.complete(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        },
      ),
    );

    final raced = completer.future.timeout(
      requestTimeout,
      onTimeout: () => throw const ApiTimeout(),
    );
    try {
      final winner = await Future.any<dynamic>([
        raced,
        if (cancelToken != null)
          cancelToken.whenCancel.then<dynamic>(
            (_) => throw const ApiCancelled(),
          ),
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
  final network = ref.watch(pixivNetworkFactoryProvider);
  // C10: the Pixiv API follows the UI language. The client is rebuilt when
  // the setting changes so every request carries the current language tag.
  final languageTag = ref.watch(
    settingsProvider.select((async) => async.value?.languageTag ?? 'zh-CN'),
  );
  return PixivHttpClient(
    client: network.client(PixivDestinationPurpose.appApi),
    accountStore: ref.watch(accountStoreProvider.notifier),
    credentialStore: ref.watch(credentialStoreProvider),
    oauthService: ref.watch(oauthServiceProvider),
    languageTag: languageTag,
  );
});

class _GetRequestFlightKey {
  const _GetRequestFlightKey(this.uri, this.accessToken);

  final Uri uri;
  final String accessToken;

  @override
  bool operator ==(Object other) =>
      other is _GetRequestFlightKey &&
      other.uri == uri &&
      other.accessToken == accessToken;

  @override
  int get hashCode => Object.hash(uri, accessToken);
}
