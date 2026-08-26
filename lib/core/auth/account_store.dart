import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account.dart';
import 'account_repository.dart';
import 'credential.dart';
import 'credential_store.dart';

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
  Future<void> reload() async {
    state = const AsyncLoading<AccountState>();
    state = await AsyncValue.guard(() => build());
  }

  /// Adds an account (or refreshes credentials of an existing one) and makes
  /// it current, mirroring the beta56 add-then-select behaviour.
  Future<void> upsertAccount(Account account, Credential credential) async {
    final repository = ref.read(accountMetadataRepositoryProvider);
    final credentials = ref.read(credentialStoreProvider);
    final current = state.requireValue;

    try {
      await credentials.write(account.id, credential);
    } on Object catch (error) {
      state = AsyncData(current.copyWith(
        status: AccountStatus.failure,
        error: error,
      ));
      return;
    }
    try {
      final accounts = [
        ...current.accounts.where((existing) => existing.id != account.id),
        account.copyWith(authState: AccountAuthState.authenticated),
      ];
      await repository.save(accounts, account.id);
      state = AsyncData(AccountState(
        status: AccountStatus.ready,
        accounts: accounts,
        currentId: account.id,
      ));
    } on Object catch (error) {
      // Metadata failed to commit: roll the secret back so no half-added
      // account lingers in secure storage.
      try {
        await credentials.delete(account.id);
      } on Object catch (rollbackError) {
        state = AsyncData(current.copyWith(
          status: AccountStatus.failure,
          error: rollbackError,
        ));
        return;
      }
      state = AsyncData(current.copyWith(
        status: AccountStatus.failure,
        error: error,
      ));
      return;
    }
  }

  /// Updates the stored user profile metadata of an existing account.
  Future<void> updateAccount(Account account) async {
    final repository = ref.read(accountMetadataRepositoryProvider);
    final current = state.requireValue;
    final accounts = current.accounts
        .map((existing) => existing.id == account.id ? account : existing)
        .toList();
    final currentId = current.currentId;
    await repository.save(accounts, currentId);
    state = AsyncData(AccountState(
      status: AccountStatus.ready,
      accounts: accounts,
      currentId: currentId,
    ));
  }

  /// Switches the current account to [accountId].
  Future<void> switchAccount(String accountId) async {
    final repository = ref.read(accountMetadataRepositoryProvider);
    final current = state.requireValue;
    if (!current.accounts.any((account) => account.id == accountId)) {
      throw AccountDataException('cannot switch to unknown account $accountId');
    }
    await repository.save(current.accounts, accountId);
    state = AsyncData(current.copyWith(currentId: accountId));
  }

  /// Marks an account as needing a fresh login.
  Future<void> markReauthRequired(String accountId) async {
    final repository = ref.read(accountMetadataRepositoryProvider);
    final current = state.requireValue;
    final accounts = current.accounts
        .map((account) => account.id == accountId
            ? account.copyWith(authState: AccountAuthState.reauthRequired)
            : account)
        .toList();
    await repository.save(accounts, current.currentId);
    state = AsyncData(current.copyWith(accounts: accounts));
  }

  /// Removes an account entirely (beta56 logout removes the account).
  Future<void> removeAccount(String accountId) async {
    final repository = ref.read(accountMetadataRepositoryProvider);
    final credentials = ref.read(credentialStoreProvider);
    final current = state.requireValue;

    final accounts =
        current.accounts.where((account) => account.id != accountId).toList();
    final nextCurrentId = current.currentId == accountId
        ? (accounts.isNotEmpty ? accounts.first.id : null)
        : current.currentId;
    await repository.save(accounts, nextCurrentId);
    state = AsyncData(AccountState(
      status: AccountStatus.ready,
      accounts: accounts,
      currentId: nextCurrentId,
    ));
    // The metadata no longer references the secret; cleanup failures are
    // surfaced but do not roll the removal back.
    await credentials.delete(accountId);
  }

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
        resolved.add(credential == null
            ? account.copyWith(authState: AccountAuthState.reauthRequired)
            : account);
      } on CredentialStoreException {
        resolved.add(account.copyWith(
          authState: AccountAuthState.reauthRequired,
        ));
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
}

Account? _byId(List<Account> accounts, String id) {
  for (final account in accounts) {
    if (account.id == id) return account;
  }
  return null;
}

final accountMetadataRepositoryProvider =
    Provider<AccountMetadataRepository>((ref) {
  return PreferencesAccountMetadataRepository();
});

final credentialStoreProvider = Provider<CredentialStore>((ref) {
  return SecureCredentialStore();
});

final accountStoreProvider =
    AsyncNotifierProvider<AccountStore, AccountState>(AccountStore.new);

