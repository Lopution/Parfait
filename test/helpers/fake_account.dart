import 'package:flutter_riverpod/misc.dart';

import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';

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
