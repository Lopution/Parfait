import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_repository.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/credential_store.dart';

/// Simple in-memory credential store for tests whose account behavior is not
/// itself the subject of the test.
class FakeCredentialStore implements CredentialStore {
  FakeCredentialStore({Map<String, Credential>? values})
    : values = {...?values};

  final Map<String, Credential> values;

  void seed(String accountId, Credential credential) {
    values[accountId] = credential;
  }

  @override
  Future<Credential?> read(String accountId) async => values[accountId];

  @override
  Future<void> write(String accountId, Credential credential) async {
    values[accountId] = credential;
  }

  @override
  Future<void> delete(String accountId) async {
    values.remove(accountId);
  }
}

/// Simple mutable account metadata repository for tests with ordinary
/// successful load/save behavior.
class FakeAccountMetadataRepository implements AccountMetadataRepository {
  FakeAccountMetadataRepository({
    Iterable<Account> accounts = const [],
    this.currentId,
  }) : accounts = List<Account>.of(accounts);

  List<Account> accounts;
  String? currentId;

  @override
  Future<AccountMetadataSnapshot> load() async => AccountMetadataSnapshot(
    accounts: List<Account>.of(accounts),
    currentId: currentId,
  );

  @override
  Future<void> save(List<Account> next, String? nextCurrentId) async {
    accounts = List<Account>.of(next);
    currentId = nextCurrentId;
  }
}

/// Standard overrides for account-backed providers.
List<Override> accountProviderOverrides({
  CredentialStore? credentialStore,
  AccountMetadataRepository? metadataRepository,
}) {
  return [
    credentialStoreProvider.overrideWithValue(
      credentialStore ?? FakeCredentialStore(),
    ),
    accountMetadataRepositoryProvider.overrideWithValue(
      metadataRepository ?? FakeAccountMetadataRepository(),
    ),
  ];
}

/// An [AccountStore] that is ready with [accounts] signed in and
/// [currentId] (the first account by default) current, for tests that need
/// accounts but none of the stores behind the real one.
class StubAccountStore extends AccountStore {
  StubAccountStore({
    this.accounts = const [Account(id: '100', userId: 100, name: 'a')],
    String? currentId,
  }) : _initialId = currentId ?? accounts.first.id;

  final List<Account> accounts;
  final String _initialId;

  @override
  Future<AccountState> build() async => _ready(_initialId);

  /// Makes [accountId] current without the metadata repository or a
  /// network session.
  void switchCurrentTo(String accountId, {int credentialRevision = 0}) =>
      state = AsyncData(_ready(accountId, credentialRevision));

  AccountState _ready(String currentId, [int credentialRevision = 0]) =>
      AccountState(
        status: AccountStatus.ready,
        accounts: accounts,
        currentId: currentId,
        credentialRevision: credentialRevision,
      );
}

/// Two signed-in accounts, '100' and '200', for account-switch tests.
const stubAccountPair = [
  Account(id: '100', userId: 100, name: 'a'),
  Account(id: '200', userId: 200, name: 'b'),
];
