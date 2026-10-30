import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/actionqueue/action_bootstrap.dart';
import 'package:parfait/core/actionqueue/action_models.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_repository.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/credential_store.dart';
import 'package:parfait/core/history/history_repository.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'helpers/fake_account.dart';
import 'helpers/history_world.dart';
import 'helpers/test_preferences.dart';

class InMemoryCredentialStore implements CredentialStore {
  final Map<String, Credential> _secrets = {};
  final Set<String> _brokenAccounts = {};
  final Set<String> _failWrites = {};

  void breakAccount(String accountId) => _brokenAccounts.add(accountId);
  void failWritesFor(String accountId) => _failWrites.add(accountId);

  /// Holds the next write until completed.
  Completer<void>? holdWrite;

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
    final hold = holdWrite;
    holdWrite = null;
    await hold?.future;
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

/// Preferences whose process dies (they throw) once [writesLeft] more
/// writes have landed.
final class _DyingPreferences extends InMemorySharedPreferencesAsync {
  _DyingPreferences() : super.empty();

  int? writesLeft;

  Future<bool> _write(Future<bool> Function() write) {
    if (writesLeft case final left?) {
      if (left == 0) throw StateError('process died');
      writesLeft = left - 1;
    }
    return write();
  }

  @override
  Future<bool> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) => _write(() => super.setString(key, value, options));

  @override
  Future<bool> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) => _write(() => super.setStringList(key, value, options));

  @override
  Future<bool> clear(
    ClearPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) => _write(() => super.clear(parameters, options));
}

Account account(
  String id, {
  AccountAuthState state = AccountAuthState.authenticated,
}) {
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

/// Secure storage that refuses to delete, as a broken keystore would.
class _DeleteFailingCredentials extends InMemoryCredentialStore {
  @override
  Future<void> delete(String accountId) async => throw StateError('keystore');
}

/// The store over the app's metadata repository on [GatedPreferences],
/// whose writes a case can hold or fail.
(ProviderContainer, InMemoryCredentialStore, GatedPreferences) makeContainer() {
  final credentials = InMemoryCredentialStore();
  final preferences = GatedPreferences();
  installPreferencesForTest(preferences);
  final container = ProviderContainer.test(
    overrides: [credentialStoreProvider.overrideWithValue(credentials)],
  );
  return (container, credentials, preferences);
}

Future<List<String>> storedIds() async => [
  for (final account in (await storedAccounts().load()).accounts) account.id,
];

/// A view of [accountId] stored locally and queued for pixiv.
Future<void> viewOnce(HistoryRepository history, String accountId) =>
    history.commitView(
      record: historyRecord(1, accountId: accountId),
      writeLocal: true,
      enqueuePixiv: true,
      unsubmittedPixivDuration: const Duration(seconds: 10),
    );

void main() {
  test('hydration with no persisted data yields empty ready state', () async {
    final (container, _, _) = makeContainer();
    final state = await container.read(accountStoreProvider.future);
    expect(state.status, AccountStatus.ready);
    expect(state.hasAccounts, isFalse);
    expect(state.current, isNull);
  });

  test('upsert adds or refreshes an account and selects it', () async {
    final (container, credentials, _) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);
    AccountState state() => container.read(accountStoreProvider).requireValue;

    await store.upsertAccount(account('100'), credential('100'));
    await store.upsertAccount(account('200'), credential('200'));
    expect(state().accounts.map((a) => a.id), ['100', '200']);
    expect(state().currentId, '200');
    expect(await credentials.read('200'), isNotNull);

    await store.upsertAccount(
      account('100'),
      const Credential(accessToken: 'new-access', refreshToken: 'new-refresh'),
    );
    expect(state().accounts.map((a) => a.id), unorderedEquals(['100', '200']));
    expect(state().currentId, '100');
    final stored = await credentials.read('100');
    expect(stored!.accessToken, 'new-access');
    expect(stored.refreshToken, 'new-refresh');
  });

  test('switchAccount changes current and persists across hydration', () async {
    final (container, credentials, _) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('100'));
    await store.upsertAccount(account('200'), credential('200'));
    await store.switchAccount('100');
    expect(container.read(accountStoreProvider).requireValue.currentId, '100');

    // Simulate an app restart: fresh container over the same storage.
    final restarted = ProviderContainer(
      overrides: [credentialStoreProvider.overrideWithValue(credentials)],
    );
    addTearDown(restarted.dispose);
    final state = await restarted.read(accountStoreProvider.future);
    expect(state.currentId, '100');
    expect(state.usableCurrent!.id, '100');
  });

  test('metadata cut short at any write still loads', () async {
    for (final (before, beforeCurrent, after, afterCurrent) in [
      (['100', '200'], '200', ['100'], '100'), // remove the current account
      (['100'], '100', <String>[], null), // remove the last one
      (['100'], '100', ['100', '200'], '200'), // add and select
    ]) {
      for (var writes = 0; writes < 3; writes++) {
        final preferences = _DyingPreferences();
        SharedPreferencesAsyncPlatform.instance = preferences;
        final repository = PreferencesAccountMetadataRepository(
          preferences: SharedPreferencesAsync(),
        );
        await repository.save(before.map(account).toList(), beforeCurrent);
        preferences.writesLeft = writes;
        try {
          await repository.save(after.map(account).toList(), afterCurrent);
        } on StateError {
          // Died mid-save.
        }
        preferences.writesLeft = null;
        final loaded = await repository.load();
        expect(
          [beforeCurrent, afterCurrent],
          contains(loaded.currentId),
          reason: '$before → $after, died after $writes writes',
        );
      }
    }
  });

  test('a refresh saved mid-way neither revives nor reselects', () async {
    final (container, credentials, preferences) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);
    await store.upsertAccount(account('100'), credential('100'));
    await store.upsertAccount(account('200'), credential('200'));
    AccountState state() => container.read(accountStoreProvider).requireValue;

    // Removed while the refreshed credential is being written.
    final writing = credentials.holdWrite = Completer();
    final revived = store.saveRefreshed(account('100'), credential('100'));
    await pumpEventQueue();
    final removed = store.removeAccount('100');
    await pumpEventQueue();
    writing.complete();
    await removed;
    await revived;
    expect(state().accounts.map((a) => a.id), ['200']);

    // Switched while the refreshed metadata is being saved.
    await store.upsertAccount(account('100'), credential('100'));
    final saving = Completer<void>();
    preferences.writeGate = saving.future;
    final refreshed = store.saveRefreshed(account('100'), credential('100'));
    await pumpEventQueue();
    final switched = store.switchAccount('200');
    await pumpEventQueue();
    saving.complete();
    await Future.wait([refreshed, switched]);
    expect(state().currentId, '200');
  });

  test(
    'failed credential write leaves no half-added metadata account',
    () async {
      final (container, credentials, _) = makeContainer();
      credentials.failWritesFor('300');
      final store = container.read(accountStoreProvider.notifier);
      await container.read(accountStoreProvider.future);

      await store.upsertAccount(account('100'), credential('100'));
      await store.upsertAccount(account('300'), credential('300'));

      final state = container.read(accountStoreProvider).requireValue;
      expect(state.accounts.map((a) => a.id), ['100']);
      expect(state.status, AccountStatus.failure);
      expect(await storedIds(), ['100']);
    },
  );

  test('failed metadata commit rolls the credential back', () async {
    final (container, credentials, preferences) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('100'));
    preferences.writeGate = Future<void>.error(StateError('disk full'))
      ..ignore();
    await store.upsertAccount(account('400'), credential('400'));

    final state = container.read(accountStoreProvider).requireValue;
    expect(state.accounts.map((a) => a.id), ['100']);
    expect(
      await credentials.read('400'),
      isNull,
      reason: 'credential must be rolled back when metadata fails',
    );
  });

  test('failed metadata refresh restores the previous credential', () async {
    final (container, credentials, preferences) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('old'));
    preferences.writeGate = Future<void>.error(StateError('disk full'))
      ..ignore();
    await store.upsertAccount(account('100'), credential('new'));

    final restored = await credentials.read('100');
    expect(restored!.accessToken, 'access-token-old');
    expect(restored.refreshToken, 'refresh-token-old');
    expect(
      container.read(accountStoreProvider).requireValue.accounts.single.name,
      'user100',
    );
  });

  test(
    'unreadable credential on hydration marks reauthRequired, not absent',
    () async {
      final (container, credentials, _) = makeContainer();
      final store = container.read(accountStoreProvider.notifier);
      await container.read(accountStoreProvider.future);
      await store.upsertAccount(account('100'), credential('100'));

      credentials.breakAccount('100');

      final restarted = ProviderContainer(
        overrides: [credentialStoreProvider.overrideWithValue(credentials)],
      );
      addTearDown(restarted.dispose);
      final state = await restarted.read(accountStoreProvider.future);
      expect(state.accounts, hasLength(1));
      expect(state.accounts.single.authState, AccountAuthState.reauthRequired);
      expect(state.usableCurrent, isNull);
    },
  );

  test('corrupt metadata surfaces an explicit failure state', () async {
    final (container, credentials, _) = makeContainer();
    await seedCorruptAccounts();

    final state = await container.read(accountStoreProvider.future);
    expect(state.status, AccountStatus.failure);
    expect(state.error, isA<AccountDataException>());
    // The credential store was untouched.
    expect(credentials._secrets, isEmpty);
  });

  test('markReauthRequired persists the degraded auth state', () async {
    final (container, _, _) = makeContainer();
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);

    await store.upsertAccount(account('100'), credential('100'));
    await store.markReauthRequired('100');

    final state = container.read(accountStoreProvider).requireValue;
    expect(state.accounts.single.authState, AccountAuthState.reauthRequired);
    expect(
      (await storedAccounts().load()).accounts.single.authState,
      AccountAuthState.reauthRequired,
    );
  });

  test('account JSON keeps isPremium and holds no secrets', () {
    final premium = account('100').copyWith(isPremium: true);
    expect(Account.fromJson(premium.toJson()).isPremium, isTrue);
    // Older payloads without the flag deserialize as free, never premium.
    expect(Account.fromJson(account('100').toJson()).isPremium, isFalse);
    expect(
      premium.toJson().keys,
      isNot(contains(anyOf('accessToken', 'refreshToken', 'cookie'))),
    );
  });

  test('credential toString is redacted', () {
    final value = credential('100').toString();
    expect(value.contains('access-token-100'), isFalse);
    expect(value.contains('refresh-token-100'), isFalse);
    expect(value.contains('cookie-100'), isFalse);
  });

  test(
    'removeAccount reselects, deletes the secret, the outbox, queued actions '
    'and cached feeds, keeps local history',
    () async {
      final credentials = InMemoryCredentialStore();
      final history = await openHistoryRepository(const []);
      final container = ProviderContainer.test(
        overrides: [
          credentialStoreProvider.overrideWithValue(credentials),
          historyRepositoryProvider.overrideWithValue(history),
        ],
      );

      final store = container.read(accountStoreProvider.notifier);
      await container.read(accountStoreProvider.future);
      await store.upsertAccount(account('100'), credential('100'));
      await store.upsertAccount(account('200'), credential('200'));
      // A re-added account must not replay or restore these.
      final actions = container.read(actionStoreProvider);
      final snapshots = container.read(feedSnapshotStoreProvider);
      for (final id in ['100', '200']) {
        await actions.enqueue(
          StoredAction(
            id: 0,
            owner: id,
            type: ActionTypes.bookmarkAdd,
            dedupeKey: 'illust:1',
            payload: '{}',
            status: ActionStatus.pending,
            attempt: 0,
            createdAt: 0,
          ),
        );
        await snapshots.write(id, 'recommended', ids: const [1], entities: {});
        await viewOnce(history, id);
      }
      await store.removeAccount('200');

      expect(await history.pendingOutbox(accountId: '200'), isEmpty);
      expect(await history.pendingOutbox(accountId: '100'), hasLength(1));
      expect(await history.all(accountId: '200'), hasLength(1));
      expect(await credentials.read('200'), isNull);
      expect(await actions.listFor('200'), isEmpty);
      expect(await snapshots.read('200', 'recommended'), isNull);
      expect(await actions.listFor('100'), hasLength(1));
      expect(await snapshots.read('100', 'recommended'), isNotNull);
      AccountState state() => container.read(accountStoreProvider).requireValue;
      expect(state().accounts.map((a) => a.id), ['100']);
      expect(state().currentId, '100');

      await store.removeAccount('100');
      expect(state().hasAccounts, isFalse);
      expect(state().currentId, isNull);
    },
  );

  test('a cleanup that fails leaves the others done and is surfaced', () async {
    final history = await openHistoryRepository(const []);
    final container = ProviderContainer.test(
      overrides: [
        credentialStoreProvider.overrideWithValue(_DeleteFailingCredentials()),
        historyRepositoryProvider.overrideWithValue(history),
      ],
    );
    final store = container.read(accountStoreProvider.notifier);
    await container.read(accountStoreProvider.future);
    await store.upsertAccount(account('200'), credential('200'));
    await viewOnce(history, '200');
    // The last cleanup: the ones between it and the failure ran too.
    final snapshots = container.read(feedSnapshotStoreProvider);
    await snapshots.write('200', 'recommended', ids: const [1], entities: {});

    await expectLater(store.removeAccount('200'), throwsStateError);
    expect(await history.pendingOutbox(accountId: '200'), isEmpty);
    expect(await snapshots.read('200', 'recommended'), isNull);
    expect(
      container.read(accountStoreProvider).requireValue.hasAccounts,
      isFalse,
    );
  });
}
