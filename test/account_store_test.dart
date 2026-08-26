import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class InMemoryCredentialStore implements CredentialStore {
  final Map<String, Credential> _secrets = {};
  final Set<String> _brokenAccounts = {};
  final Set<String> _failWrites = {};

  void breakAccount(String accountId) => _brokenAccounts.add(accountId);
  void failWritesFor(String accountId) => _failWrites.add(accountId);

  @override
  Future<Credential?> read(String accountId) async {
    if (_brokenAccounts.contains(accountId)) {
      throw CredentialStoreException('read', accountId, 'keystore corrupted');
    }
    return _secrets[accountId];
  }

  @override
  Future<void> write(String accountId, Credential credential) async {
    if (_failWrites.contains(accountId)) {
      throw CredentialStoreException('write', accountId, 'keystore full');
    }
    _secrets[accountId] = credential;
  }

  @override
  Future<void> delete(String accountId) async {
    if (_brokenAccounts.contains(accountId)) {
      throw CredentialStoreException('delete', accountId, 'keystore corrupted');
    }
    _secrets.remove(accountId);
  }
}

class InMemoryMetadataRepository implements AccountMetadataRepository {
  List<Account>? stored;
  String? storedCurrentId;
  bool failSave = false;
  Object? corruptOnLoad;

  @override
  Future<AccountMetadataSnapshot> load() async {
    final error = corruptOnLoad;
    if (error != null) throw error;
    final list = stored;
    if (list == null) return const AccountMetadataSnapshot(accounts: []);
    return AccountMetadataSnapshot(accounts: list, currentId: storedCurrentId);
  }

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {
    if (failSave) {
      throw AccountDataException('disk full');
    }
    stored = List.of(accounts);
    storedCurrentId = currentId;
  }
}

Account account(String id, {AccountAuthState state = AccountAuthState.authenticated}) {
  return Account(
    id: id,
    userId: int.parse(id),
    name: 'user$id',
    authState: state,
  );
}

Credential credential(String id) => Credential(
      accessToken: 'access-token-$id',
      refreshToken: 'refresh-token-$id',
      cookie: 'cookie-$id',
    );

(ProviderContainer, InMemoryCredentialStore, InMemoryMetadataRepository)
    makeContainer() {
  final credentials = InMemoryCredentialStore();
  final metadata = InMemoryMetadataRepository();
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(metadata),
    ],
  );
  addTearDown(container.dispose);
  return (container, credentials, metadata);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('hydration with no persisted data yields empty ready state', () async {
    final (container, _, _) = makeContainer();
    final state = await container.read(accountStoreProvider.future);
    expect(state.status, AccountStatus.ready);
    expect(state.hasAccounts, isFalse);
    expect(state.current, isNull);
  });

  test('upsert adds accounts and selects the newest as current', () async {
    final (container, credentials, _) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('100'));
    await store.upsertAccount(account('200'), credential('200'));

    final state = container.read(accountStoreProvider).requireValue;
    expect(state.accounts.map((a) => a.id), ['100', '200']);
    expect(state.currentId, '200');
    expect(await credentials.read('100'), isNotNull);
    expect(await credentials.read('200'), isNotNull);
  });

  test('upsert with existing id refreshes credentials in place', () async {
    final (container, credentials, _) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('100'));
    await store.upsertAccount(account('100'),
        const Credential(accessToken: 'new-access', refreshToken: 'new-refresh'));

    final state = container.read(accountStoreProvider).requireValue;
    expect(state.accounts, hasLength(1));
    final stored = await credentials.read('100');
    expect(stored!.accessToken, 'new-access');
    expect(stored.refreshToken, 'new-refresh');
  });

  test('switchAccount changes current and persists across hydration',
      () async {
    final (container, credentials, metadata) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('100'));
    await store.upsertAccount(account('200'), credential('200'));
    await store.switchAccount('100');
    expect(container.read(accountStoreProvider).requireValue.currentId, '100');

    // Simulate an app restart: fresh container over the same repositories.
    final (restarted, _, _) = (
      ProviderContainer(overrides: [
        credentialStoreProvider.overrideWithValue(credentials),
        accountMetadataRepositoryProvider.overrideWithValue(metadata),
      ]),
      credentials,
      metadata,
    );
    addTearDown(restarted.dispose);
    final state = await restarted.read(accountStoreProvider.future);
    expect(state.currentId, '100');
    expect(state.usableCurrent!.id, '100');
  });

  test('removeAccount drops current reference and deletes the secret',
      () async {
    final (container, credentials, _) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('100'));
    await store.upsertAccount(account('200'), credential('200'));
    await store.removeAccount('200');

    final state = container.read(accountStoreProvider).requireValue;
    expect(state.accounts.map((a) => a.id), ['100']);
    expect(state.currentId, '100');
    expect(await credentials.read('200'), isNull);
  });

  test('removing the last account clears current', () async {
    final (container, _, _) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('100'));
    await store.removeAccount('100');

    final state = container.read(accountStoreProvider).requireValue;
    expect(state.hasAccounts, isFalse);
    expect(state.currentId, isNull);
  });

  test('failed credential write leaves no half-added metadata account',
      () async {
    final (container, credentials, metadata) = makeContainer();
    credentials.failWritesFor('300');
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('100'));
    await store.upsertAccount(account('300'), credential('300'));

    final state = container.read(accountStoreProvider).requireValue;
    expect(state.accounts.map((a) => a.id), ['100']);
    expect(state.status, AccountStatus.failure);
    expect(metadata.stored!.map((a) => a.id), ['100']);
  });

  test('failed metadata commit rolls the credential back', () async {
    final (container, credentials, metadata) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('100'));
    metadata.failSave = true;
    await store.upsertAccount(account('400'), credential('400'));

    final state = container.read(accountStoreProvider).requireValue;
    expect(state.accounts.map((a) => a.id), ['100']);
    expect(await credentials.read('400'), isNull,
        reason: 'credential must be rolled back when metadata fails');
  });

  test('unreadable credential on hydration marks reauthRequired, not absent',
      () async {
    final (container, credentials, metadata) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);
    await store.upsertAccount(account('100'), credential('100'));

    credentials.breakAccount('100');

    final (restarted, _, _) = (
      ProviderContainer(overrides: [
        credentialStoreProvider.overrideWithValue(credentials),
        accountMetadataRepositoryProvider.overrideWithValue(metadata),
      ]),
      credentials,
      metadata,
    );
    addTearDown(restarted.dispose);
    final state = await restarted.read(accountStoreProvider.future);
    expect(state.accounts, hasLength(1));
    expect(state.accounts.single.authState, AccountAuthState.reauthRequired);
    expect(state.usableCurrent, isNull);
  });

  test('corrupt metadata surfaces an explicit failure state', () async {
    final (container, credentials, metadata) = makeContainer();
    metadata.corruptOnLoad = AccountDataException('corrupt entry');

    final state = await container.read(accountStoreProvider.future);
    expect(state.status, AccountStatus.failure);
    expect(state.error, isA<AccountDataException>());
    // The credential store was untouched.
    expect(credentials._secrets, isEmpty);
  });

  test('markReauthRequired persists the degraded auth state', () async {
    final (container, _, metadata) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('100'));
    await store.markReauthRequired('100');

    final state = container.read(accountStoreProvider).requireValue;
    expect(state.accounts.single.authState, AccountAuthState.reauthRequired);
    expect(metadata.stored!.single.authState,
        AccountAuthState.reauthRequired);
  });

  test('metadata serialization never contains secret fields', () async {
    final (container, _, _) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('100'));

    final json = account('100').toJson();
    expect(json.keys, isNot(contains(anyOf('accessToken', 'refreshToken', 'cookie'))));
  });

  test('credential toString is redacted', () {
    final value = credential('100').toString();
    expect(value.contains('access-token-100'), isFalse);
    expect(value.contains('refresh-token-100'), isFalse);
    expect(value.contains('cookie-100'), isFalse);
  });
}
