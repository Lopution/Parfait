import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_error.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import '../platform/account_transfer_clipboard.dart';
import '../user/user_entity.dart';
import 'account.dart';
import 'account_store.dart';
import 'credential.dart';
import 'credential_store.dart';
import 'account_transfer.dart';
import 'oauth_service.dart';

/// Server-authoritative account and the credential that was actually
/// verified. Clipboard metadata is never used to populate the display name.
class VerifiedTransferAccount {
  const VerifiedTransferAccount({
    required this.account,
    required this.credential,
  });

  final Account account;
  final Credential credential;
}

/// Verifies an imported credential before it reaches either account store.
abstract interface class TransferCredentialVerifier {
  Future<VerifiedTransferAccount> verify(TransferAccountPayload payload);
}

/// Pixiv App API verifier for an imported credential.
///
/// It first checks the supplied access token against the fixed user-detail
/// endpoint. If that token is expired, the supplied refresh token may be
/// exchanged once through the existing exact-host OAuth service; the refreshed
/// credential is then checked against the same authoritative profile endpoint.
class PixivTransferCredentialVerifier implements TransferCredentialVerifier {
  PixivTransferCredentialVerifier({
    required PixivHttpClient apiClient,
    required OAuthService oauthService,
  }) : _apiClient = apiClient,
       _oauthService = oauthService;

  final PixivHttpClient _apiClient;
  final OAuthService _oauthService;

  @override
  Future<VerifiedTransferAccount> verify(TransferAccountPayload payload) async {
    try {
      final user = await _fetch(payload.userId, payload.credential);
      return _authoritative(user, payload, payload.credential);
    } on ApiUnauthorized {
      return _verifyAfterRefresh(payload);
    } on ApiNetworkError catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.verificationUnavailable,
        'Pixiv credential verification is unavailable',
        cause: error,
      );
    } on ApiTimeout catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.verificationUnavailable,
        'Pixiv credential verification timed out',
        cause: error,
      );
    } on ApiCancelled catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.verificationUnavailable,
        'Pixiv credential verification was cancelled',
        cause: error,
      );
    } on ApiParseError catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.verificationUnavailable,
        'Pixiv credential response is malformed',
        cause: error,
      );
    } on ApiHttpError catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.verificationUnavailable,
        'Pixiv credential verification failed',
        cause: error,
      );
    }
  }

  Future<VerifiedTransferAccount> _verifyAfterRefresh(
    TransferAccountPayload payload,
  ) async {
    late final OAuthResult refreshed;
    try {
      refreshed = await _oauthService.refreshSession(
        payload.credential.refreshToken,
      );
    } on OAuthException catch (error) {
      if (error.statusCode != null &&
          error.statusCode! >= 400 &&
          error.statusCode! < 500) {
        throw AccountTransferException(
          AccountTransferErrorCode.credentialInvalid,
          'Pixiv credential is invalid',
          cause: error,
        );
      }
      throw AccountTransferException(
        AccountTransferErrorCode.verificationUnavailable,
        'Pixiv credential refresh is unavailable',
        cause: error,
      );
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.verificationUnavailable,
        'Pixiv credential refresh is unavailable',
        cause: error,
      );
    }
    if (refreshed.accountId != payload.accountId ||
        refreshed.profile.userId != payload.userId) {
      throw const AccountTransferException(
        AccountTransferErrorCode.credentialInvalid,
        'Pixiv credential belongs to a different account',
      );
    }
    try {
      final user = await _fetch(payload.userId, refreshed.credential);
      return _authoritative(user, payload, refreshed.credential);
    } on ApiUnauthorized catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.credentialInvalid,
        'Pixiv credential is invalid',
        cause: error,
      );
    } on ApiNetworkError catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.verificationUnavailable,
        'Pixiv credential verification is unavailable',
        cause: error,
      );
    } on ApiTimeout catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.verificationUnavailable,
        'Pixiv credential verification timed out',
        cause: error,
      );
    } on ApiParseError catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.verificationUnavailable,
        'Pixiv credential response is malformed',
        cause: error,
      );
    } on ApiHttpError catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.verificationUnavailable,
        'Pixiv credential verification failed',
        cause: error,
      );
    }
  }

  Future<UserEntity> _fetch(int userId, Credential credential) async {
    final endpoint = PixivClientIdentity.appApiBase.replace(
      path: '/v1/user/detail',
      queryParameters: {'filter': 'for_android', 'user_id': '$userId'},
    );
    final json = await _apiClient.getJsonWithCredential(
      endpoint,
      credential: credential,
    );
    try {
      return UserEntity.fromDetailJson(json);
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  VerifiedTransferAccount _authoritative(
    UserEntity user,
    TransferAccountPayload payload,
    Credential credential,
  ) {
    if (user.id != payload.userId || '${user.id}' != payload.accountId) {
      throw const AccountTransferException(
        AccountTransferErrorCode.credentialInvalid,
        'Pixiv credential belongs to a different account',
      );
    }
    return VerifiedTransferAccount(
      account: Account(
        id: '${user.id}',
        userId: user.id,
        name: user.name,
        profileImageUrl: user.profileImageUrl,
      ),
      credential: credential,
    );
  }
}

class TransferImportResult {
  const TransferImportResult({
    required this.account,
    this.clipboardCleared = false,
  });

  final Account account;
  final bool clipboardCleared;
}

/// Coordinates explicit clipboard actions, validation, server verification
/// and the existing atomic account-store write boundary.
class AccountTransferService {
  AccountTransferService({
    required AccountStore accountStore,
    required CredentialStore credentialStore,
    required TransferCredentialVerifier verifier,
    required TransferClipboard clipboard,
  }) : _accountStore = accountStore,
       _credentialStore = credentialStore,
       _verifier = verifier,
       _clipboard = clipboard;

  final AccountStore _accountStore;
  final CredentialStore _credentialStore;
  final TransferCredentialVerifier _verifier;
  final TransferClipboard _clipboard;

  Future<void> exportCurrentToClipboard() async {
    final state = await _accountStore.resolveState();
    final account = state.usableCurrent;
    if (account == null) {
      throw const AccountTransferException(
        AccountTransferErrorCode.noUsableAccount,
        'there is no usable account to export',
      );
    }
    late final Credential credential;
    try {
      credential =
          await _credentialStore.read(account.id) ??
          (throw const AccountTransferException(
            AccountTransferErrorCode.credentialUnavailable,
            'the account credential is unavailable',
          ));
    } on AccountTransferException {
      rethrow;
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.credentialUnavailable,
        'the account credential is unavailable',
        cause: error,
      );
    }
    final envelope = TransferEnvelope.create(
      account: account,
      credential: credential,
    );
    await _clipboard.write(
      envelope.encode(),
      clearAfter: transferClipboardLifetime,
    );
  }

  /// Reads the clipboard only from this explicit user action.
  Future<TransferImportResult> importFromClipboard() async {
    final content = await _clipboard.read();
    if (content == null) {
      throw const AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard does not contain account-transfer data',
      );
    }
    TransferEnvelope? envelope;
    try {
      envelope = TransferEnvelope.parse(content.text);
    } catch (error, stackTrace) {
      // A malformed value has not been identified as our envelope, so it is
      // never cleared. Preserve the typed parser error and stack for callers.
      Error.throwWithStackTrace(error, stackTrace);
    }

    try {
      final imported = await _importEnvelope(envelope);
      final cleared = await _clipboard.clearIfCurrent(content.fingerprint);
      return TransferImportResult(
        account: imported.account,
        clipboardCleared: cleared,
      );
    } catch (error, stackTrace) {
      // Once parsing succeeded, the clipboard value is recognized as an
      // envelope even when the credential turns out to be invalid. Clear it
      // only if the fingerprint still matches, keeping the primary failure.
      try {
        await _clipboard.clearIfCurrent(content.fingerprint);
      } catch (cleanupError) {
        if (error is AccountTransferException) {
          throw AccountTransferException(
            error.code,
            error.publicMessage,
            cause: (error.cause, cleanupError),
          );
        }
        Error.throwWithStackTrace(cleanupError, stackTrace);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<TransferImportResult> _importEnvelope(
    TransferEnvelope envelope,
  ) async {
    late final VerifiedTransferAccount verified;
    try {
      verified = await _verifier.verify(envelope.payload);
    } on AccountTransferException {
      rethrow;
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.verificationUnavailable,
        'Pixiv credential verification is unavailable',
        cause: error,
      );
    }
    await _accountStore.upsertAccount(verified.account, verified.credential);
    final state = await _accountStore.resolveState();
    if (state.status == AccountStatus.failure ||
        state.current?.id != verified.account.id ||
        state.current?.userId != verified.account.userId ||
        state.current?.authState != AccountAuthState.authenticated) {
      throw const AccountTransferException(
        AccountTransferErrorCode.storageFailure,
        'account import could not be committed atomically',
      );
    }
    return TransferImportResult(account: verified.account);
  }
}

final transferClipboardProvider = Provider<TransferClipboard>((ref) {
  return MethodChannelTransferClipboard();
});

final transferCredentialVerifierProvider = Provider<TransferCredentialVerifier>(
  (ref) {
    return PixivTransferCredentialVerifier(
      apiClient: ref.watch(pixivHttpClientProvider),
      oauthService: ref.watch(oauthServiceProvider),
    );
  },
);

final accountTransferServiceProvider = Provider<AccountTransferService>((ref) {
  return AccountTransferService(
    accountStore: ref.watch(accountStoreProvider.notifier),
    credentialStore: ref.watch(credentialStoreProvider),
    verifier: ref.watch(transferCredentialVerifierProvider),
    clipboard: ref.watch(transferClipboardProvider),
  );
});
