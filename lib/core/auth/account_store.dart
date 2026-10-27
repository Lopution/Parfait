/// Account state, OAuth hydration, and per-account credential lifecycle.
/// [AccountStore] owns the observable account boundary; [CredentialStore]
/// owns secure token storage. See `backend/stores.md`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../settings/shared_preferences.dart';

import 'account.dart';
import 'account_repository.dart';
import 'credential.dart';
import 'credential_store.dart';
import 'oauth_service.dart';
import '../history/history_repository.dart';
import '../network/compat/network_contracts.dart';
import '../network/compat/network_providers.dart';

/// Lifecycle status of the account domain.
enum AccountStatus { ready, failure }

/// Observable state of the account domain.
class AccountState {
  const AccountState({
    required this.status,
    this.accounts = const [],
    this.currentId,
    this.error,
  });

  final AccountStatus status;

  /// All known accounts, including ones pending re-authentication.
  final List<Account> accounts;
  final String? currentId;
  final Object? error;

  bool get hasAccounts => accounts.isNotEmpty;

  Account? get current =>
      currentId == null ? null : _byId(accounts, currentId!);

  /// The account that should drive authenticated UI, if any. Accounts in the
  /// re-auth required state do not count as usable.
  Account? get usableCurrent {
    final account = current;
    if (account == null ||
        account.authState == AccountAuthState.reauthRequired) {
      return null;
    }
    return account;
  }

  AccountState copyWith({
    AccountStatus? status,
    List<Account>? accounts,
    String? currentId,
    Object? error,
  }) {
    return AccountState(
      status: status ?? this.status,
      accounts: accounts ?? this.accounts,
      currentId: currentId ?? this.currentId,
      error: error,
    );
  }
}

/// Coordinates secure credentials and plain metadata for all accounts.
///
/// Commit order keeps the domain recoverable:
/// - add/update: secure credential first, metadata second. A metadata failure
///   rolls the credential back so no half-added account is visible.
/// - remove: metadata reference first, secret cleanup second.
class AccountStore extends AsyncNotifier<AccountState> {
  @override
  Future<AccountState> build() async {
    final repository = ref.watch(accountMetadataRepositoryProvider);
    final credentials = ref.watch(credentialStoreProvider);
    try {
      final snapshot = await repository.load();
      final accounts = await _resolveAuthStates(credentials, snapshot.accounts);
      return AccountState(
        status: AccountStatus.ready,
        accounts: accounts,
        currentId: _validCurrentId(snapshot.currentId, accounts),
      );
    } on AccountDataException catch (error) {
      return AccountState(status: AccountStatus.failure, error: error);
    }
  }

  /// Re-runs hydration, e.g. after the user acknowledges a failure.
  Future<void> reload() => _serial(() async {
    state = const AsyncLoading<AccountState>();
    state = await AsyncValue.guard(() => build());
  });

  /// Public snapshot accessor for collaborators outside riverpod internals
  /// (e.g. the network client).
  Future<AccountState> resolveState() => future;

  /// Account mutations run one at a time: each reads, persists and
  /// publishes the state before the next one starts, so a late token
  /// refresh can neither undo a switch nor bring back a removed account.
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() mutation) {
    final result = _tail.then((_) => mutation());
    _tail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  /// Adds an account (or refreshes credentials of an existing one) and makes
  /// it current, mirroring the beta56 add-then-select behaviour.
  /// [stillWanted] is asked once more right before anything is written: a
  /// login whose page closed while it waited saves nothing.
  Future<void> upsertAccount(
    Account account,
    Credential credential, {
    bool Function()? stillWanted,
  }) => _serial(
    () => _commit(account, credential, select: true, stillWanted: stillWanted),
  );

  /// Saves a refreshed session of [account] while it is still stored,
  /// leaving the current account and the network session as they are.
  /// False when the account was removed while the refresh ran.
  Future<bool> saveRefreshed(Account account, Credential credential) =>
      _serial(() async {
        final current = await future;
        if (!current.accounts.any((existing) => existing.id == account.id)) {
          return false;
        }
        await _commit(account, credential, select: false);
        return true;
      });

  Future<void> _commit(
    Account account,
    Credential credential, {
    required bool select,
    bool Function()? stillWanted,
  }) async {
    final repository = ref.read(accountMetadataRepositoryProvider);
    final credentials = ref.read(credentialStoreProvider);
    // A first-login tap can arrive before the cold-start hydration has
    // completed. Waiting for the same observable snapshot avoids a transient
    // StateError that leaves the WebView on its loading surface and makes the
    // login appear stuck. Subsequent calls are already completed futures.
    final current = await future;
    final hasExistingMetadata = current.accounts.any(
      (existing) => existing.id == account.id,
    );
    Credential? previousCredential;
    if (hasExistingMetadata) {
      try {
        previousCredential = await credentials.read(account.id);
      } on Object catch (error) {
        state = AsyncData(
          current.copyWith(status: AccountStatus.failure, error: error),
        );
        return;
      }
    }
    if (stillWanted?.call() == false) return;

    try {
      await credentials.write(account.id, credential);
    } on Object catch (error) {
      state = AsyncData(
        current.copyWith(status: AccountStatus.failure, error: error),
      );
      return;
    }
    try {
      final saved = account.copyWith(authState: AccountAuthState.authenticated);
      final accounts = select
          ? [
              ...current.accounts.where(
                (existing) => existing.id != account.id,
              ),
              saved,
            ]
          : [
              for (final existing in current.accounts)
                existing.id == account.id ? saved : existing,
            ];
      final currentId = select ? account.id : current.currentId;
      await repository.save(accounts, currentId);
      state = AsyncData(
        AccountState(
          status: AccountStatus.ready,
          accounts: accounts,
          currentId: currentId,
        ),
      );
      if (select) _resetNetworkSession();
    } on Object catch (error) {
      // Metadata failed to commit: restore the previous secret for an
      // existing account, or remove the new secret for a new account. This
      // prevents a failed migration/refresh from destroying a usable login.
      try {
        if (hasExistingMetadata && previousCredential != null) {
          await credentials.write(account.id, previousCredential);
        } else {
          await credentials.delete(account.id);
        }
      } on Object catch (rollbackError) {
        state = AsyncData(
          current.copyWith(status: AccountStatus.failure, error: rollbackError),
        );
        return;
      }
      state = AsyncData(
        current.copyWith(status: AccountStatus.failure, error: error),
      );
      return;
    }
  }

  /// Updates the stored user profile metadata of an existing account.
  Future<void> updateAccount(Account account) => _serial(() async {
    final repository = ref.read(accountMetadataRepositoryProvider);
    final current = state.requireValue;
    final accounts = current.accounts
        .map((existing) => existing.id == account.id ? account : existing)
        .toList();
    final currentId = current.currentId;
    await repository.save(accounts, currentId);
    state = AsyncData(
      AccountState(
        status: AccountStatus.ready,
        accounts: accounts,
        currentId: currentId,
      ),
    );
  });

  /// Switches the current account to [accountId].
  Future<void> switchAccount(String accountId) => _serial(() async {
    final repository = ref.read(accountMetadataRepositoryProvider);
    final current = state.requireValue;
    if (!current.accounts.any((account) => account.id == accountId)) {
      throw AccountDataException('cannot switch to unknown account $accountId');
    }
    await repository.save(current.accounts, accountId);
    state = AsyncData(current.copyWith(currentId: accountId));
    if (current.currentId != accountId) _resetNetworkSession();
  });

  /// Marks an account as needing a fresh login.
  Future<void> markReauthRequired(String accountId) => _serial(() async {
    final repository = ref.read(accountMetadataRepositoryProvider);
    final current = state.requireValue;
    final accounts = current.accounts
        .map(
          (account) => account.id == accountId
              ? account.copyWith(authState: AccountAuthState.reauthRequired)
              : account,
        )
        .toList();
    await repository.save(accounts, current.currentId);
    state = AsyncData(current.copyWith(accounts: accounts));
    if (current.currentId == accountId) _resetNetworkSession();
  });

  /// Removes an account entirely (beta56 logout removes the account).
  Future<void> removeAccount(String accountId) => _serial(() async {
    final repository = ref.read(accountMetadataRepositoryProvider);
    final credentials = ref.read(credentialStoreProvider);
    final current = state.requireValue;

    final accounts = current.accounts
        .where((account) => account.id != accountId)
        .toList();
    final nextCurrentId = current.currentId == accountId
        ? (accounts.isNotEmpty ? accounts.first.id : null)
        : current.currentId;
    await repository.save(accounts, nextCurrentId);
    state = AsyncData(
      AccountState(
        status: AccountStatus.ready,
        accounts: accounts,
        currentId: nextCurrentId,
      ),
    );
    if (current.currentId == accountId) _resetNetworkSession();
    // The metadata no longer references the secret; cleanup failures are
    // surfaced but do not roll the removal back.
    await credentials.delete(accountId);
    // C21: only this account's unsent remote-history outbox is dropped.
    // Local history rows stay; a re-added account never replays outbox
    // entries from a previous lifecycle.
    await ref.read(historyRepositoryProvider).clearOutbox(accountId);
  });

  Future<List<Account>> _resolveAuthStates(
    CredentialStore credentials,
    List<Account> accounts,
  ) async {
    final resolved = <Account>[];
    for (final account in accounts) {
      if (account.authState == AccountAuthState.reauthRequired) {
        resolved.add(account);
        continue;
      }
      try {
        final credential = await credentials.read(account.id);
        resolved.add(
          credential == null
              ? account.copyWith(authState: AccountAuthState.reauthRequired)
              : account,
        );
      } on CredentialStoreException {
        resolved.add(
          account.copyWith(authState: AccountAuthState.reauthRequired),
        );
      }
    }
    return resolved;
  }

  String? _validCurrentId(String? currentId, List<Account> accounts) {
    if (currentId == null) return null;
    return accounts.any((account) => account.id == currentId)
        ? currentId
        : null;
  }

  void _resetNetworkSession() {
    ref.read(networkAccessPolicyProvider).advanceNetworkRevision();
  }
}

Account? _byId(List<Account> accounts, String id) {
  for (final account in accounts) {
    if (account.id == id) return account;
  }
  return null;
}

final accountMetadataRepositoryProvider = Provider<AccountMetadataRepository>((
  ref,
) {
  return PreferencesAccountMetadataRepository(
    preferences: ref.watch(sharedPreferencesProvider),
  );
});

final credentialStoreProvider = Provider<CredentialStore>((ref) {
  return SecureCredentialStore();
});

final accountStoreProvider = AsyncNotifierProvider<AccountStore, AccountState>(
  AccountStore.new,
);

/// A build's or method's ref with the account it loads for, taken before
/// its first await, for writes into shared account-scoped stores.
/// `ref.mounted` alone lags a switch: a dependent rebuilds lazily — at the
/// next frame, or at its next read when nothing listens — so the old ref
/// stays mounted while the stores it writes to already serve the next
/// account.
final class AccountClaim {
  AccountClaim(this.ref) : accountId = _currentAccountId(ref);

  final Ref ref;
  final String? accountId;

  /// Whether [ref] is still its provider's and [accountId] still current.
  bool get holds => ref.mounted && _currentAccountId(ref) == accountId;

  static String? _currentAccountId(Ref ref) =>
      ref.read(accountStoreProvider).value?.current?.id;
}

final oauthServiceProvider = Provider<OAuthService>((ref) {
  return OAuthService(
    client: ref
        .watch(pixivNetworkFactoryProvider)
        .client(PixivDestinationPurpose.oauth),
  );
});
