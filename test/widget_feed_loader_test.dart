import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/widget/widget_feed_loader.dart';
import 'package:pixiv_func/core/widget/widget_snapshot.dart';
import 'package:pixiv_func/core/widget/widget_snapshot_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _CredentialStore implements CredentialStore {
  final _secrets = <String, Credential>{};

  void seed(String accountId, Credential credential) =>
      _secrets[accountId] = credential;

  @override
  Future<Credential?> read(String accountId) async => _secrets[accountId];

  @override
  Future<void> write(String accountId, Credential credential) async =>
      _secrets[accountId] = credential;

  @override
  Future<void> delete(String accountId) async => _secrets.remove(accountId);
}

class _FailingWriteStore extends WidgetSnapshotStore {
  _FailingWriteStore(super.directory);

  bool failWrites = false;

  @override
  Future<void> write(WidgetSnapshot snapshot, Map<String, List<int>> images) {
    if (failWrites) {
      throw StateError('injected write failure');
    }
    return super.write(snapshot, images);
  }
}

class _MetadataRepository implements AccountMetadataRepository {
  _MetadataRepository(this.accounts, this.currentId);

  final List<Account> accounts;
  final String? currentId;

  @override
  Future<AccountMetadataSnapshot> load() async =>
      AccountMetadataSnapshot(accounts: accounts, currentId: currentId);

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

String _illustJson(int id, {int xRestrict = 0}) => jsonEncode({
  'id': id,
  'title': 't$id',
  'x_restrict': xRestrict,
  'user': {
    'id': 100 + id,
    'name': 'u$id',
    'account': 'acc$id',
    'profile_image_url': 'https://i.pximg.net/p$id.png',
  },
  'image_urls': {
    'square_medium': 'https://i.pximg.net/c${id}_sq.jpg',
    'medium': 'https://i.pximg.net/c${id}_m.jpg',
    'large': 'https://i.pximg.net/c${id}_l.jpg',
  },
});

/// Mutable test transport set: the recommended page response and the cover
/// image responses are reconfigured per test case.
class _Transports {
  Object? pageBehavior; // String body+200, or an Object to throw.
  int coverStatus = 200;
  List<int> coverBytes = List.filled(64, 7);
  final pages = <http.Request>[];
  Future<void> Function()? beforeFirstCover;
  bool _firstCoverStarted = false;

  http.Client api() => MockClient((request) async {
    pages.add(request);
    final behavior = pageBehavior;
    if (behavior is http.ClientException) throw behavior;
    if (behavior is String) return http.Response(behavior, 200);
    if (behavior is int) return http.Response('{"error":"x"}', behavior);
    return http.Response(
      jsonEncode({
        'illusts': [
          jsonDecode(_illustJson(1)),
          jsonDecode(_illustJson(2, xRestrict: 1)),
          jsonDecode(_illustJson(3)),
        ],
        'next_url': null,
      }),
      200,
    );
  });

  http.Client images() => MockClient((request) async {
    if (!_firstCoverStarted) {
      _firstCoverStarted = true;
      await beforeFirstCover?.call();
    }
    if (coverStatus != 200) {
      return http.Response('nope', coverStatus);
    }
    return http.Response.bytes(coverBytes, 200);
  });
}

Future<(ProviderContainer, WidgetFeedLoader, WidgetSnapshotStore, _Transports)>
_makeWorld({
  List<Account> accounts = const [
    Account(id: '100', userId: 100, name: 'user100'),
  ],
  String? currentId = '100',
  WidgetSnapshotStore? snapshotStore,
  NetworkRevision Function()? networkRevision,
}) async {
  final transports = _Transports();
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();

  final credentials = _CredentialStore();
  for (final account in accounts) {
    credentials.seed(
      account.id,
      Credential(
        accessToken: 'access-${account.id}',
        refreshToken: 'refresh-${account.id}',
      ),
    );
  }

  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        _MetadataRepository(accounts, currentId),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async => http.Response('{}', 500)),
        ),
      ),
    ],
  );
  await container.read(accountStoreProvider.future);

  final tempDir = snapshotStore == null
      ? await Directory.systemTemp.createTemp('widget_loader_test')
      : null;
  final store = snapshotStore ?? WidgetSnapshotStore(tempDir!);
  if (tempDir != null) {
    addTearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });
  }
  final loader = WidgetFeedLoader(
    apiClient: PixivHttpClient(
      client: transports.api(),
      accountStore: container.read(accountStoreProvider.notifier),
      credentialStore: credentials,
      oauthService: container.read(oauthServiceProvider),
    ),
    imageClient: transports.images(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    storeFactory: () async => store,
    networkRevision: networkRevision,
  );
  return (container, loader, store, transports);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('writes a renderable snapshot filtering R-18 covers', () async {
    final (container, loader, store, _) = await _makeWorld();
    addTearDown(container.dispose);
    final result = await loader.load();
    expect(result.outcome, WidgetFeedOutcome.written);
    final snapshot = store.read();
    expect(snapshot, isNotNull);
    expect(snapshot!.renderable, isTrue);
    // Illust 2 is R-18 and must not be in the render model.
    expect(snapshot.items.map((i) => i.illustId), unorderedEquals(<int>[1, 3]));
    for (final item in snapshot.items) {
      expect(store.hasImage(item.imageFile), isTrue);
    }
    expect(
      snapshot.items.any((item) => item.imageFile.startsWith('cover_2_')),
      isFalse,
    );
  });

  test('no signed-in account clears render state', () async {
    final (_, loader, store, _) = await _makeWorld(
      accounts: const [],
      currentId: null,
    );
    final result = await loader.load();
    expect(result.outcome, WidgetFeedOutcome.noAccount);
    expect(store.read(), isNull);
  });

  test('credential missing clears render state', () async {
    final (container, loader, store, _) = await _makeWorld();
    addTearDown(container.dispose);
    // Same shape as reauth-required: metadata exists, secret is gone.
    await container.read(credentialStoreProvider).delete('100');
    final result = await loader.load();
    expect(result.outcome, WidgetFeedOutcome.noAccount);
    expect(store.read(), isNull);
  });

  test('auth failure clears render state (no stale artwork)', () async {
    final (container, loader, store, transports) = await _makeWorld();
    addTearDown(container.dispose);
    transports.pageBehavior = 401;
    final result = await loader.load();
    expect(result.outcome, WidgetFeedOutcome.authRequired);
    expect(store.read(), isNull);
  });

  test('transient network failure keeps same-account last-good', () async {
    final (container, loader, store, transports) = await _makeWorld();
    addTearDown(container.dispose);
    // Establish a last-good snapshot first.
    expect((await loader.load()).written, isTrue);
    final lastGood = store.read()!;
    // Next pass fails at the feed request.
    transports.pageBehavior = http.ClientException('offline');
    final result = await loader.load();
    expect(result.outcome, WidgetFeedOutcome.transientFailure);
    final stillThere = store.read();
    expect(stillThere, isNotNull);
    expect(stillThere!.accountKey, lastGood.accountKey);
    expect(stillThere.generatedAtMs, lastGood.generatedAtMs);
  });

  test('single cover failure keeps last-good and reports transient', () async {
    final (container, loader, store, transports) = await _makeWorld();
    addTearDown(container.dispose);
    expect((await loader.load()).written, isTrue);
    final lastGood = store.read()!;
    transports.coverStatus = 404;
    final result = await loader.load();
    expect(result.outcome, WidgetFeedOutcome.transientFailure);
    expect(store.read()!.generatedAtMs, lastGood.generatedAtMs);
  });

  test('snapshot write failure keeps the same-account last-good', () async {
    final tempDir = await Directory.systemTemp.createTemp('widget_loader_test');
    final failingStore = _FailingWriteStore(tempDir);
    final (container, loader, store, _) = await _makeWorld(
      snapshotStore: failingStore,
    );
    addTearDown(() async {
      container.dispose();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    expect((await loader.load()).written, isTrue);
    final lastGood = store.read()!;
    failingStore.failWrites = true;

    final result = await loader.load();
    expect(result.outcome, WidgetFeedOutcome.transientFailure);
    expect(store.read()!.generatedAtMs, lastGood.generatedAtMs);
  });

  test(
    'account switch during generation cannot publish the old account',
    () async {
      final (container, loader, store, transports) = await _makeWorld(
        accounts: const [
          Account(id: '100', userId: 100, name: 'user100'),
          Account(id: '200', userId: 200, name: 'user200'),
        ],
      );
      addTearDown(container.dispose);
      expect((await loader.load()).written, isTrue);
      final previous = store.read()!;
      transports._firstCoverStarted = false;
      transports.beforeFirstCover = () =>
          container.read(accountStoreProvider.notifier).switchAccount('200');

      final result = await loader.load();
      expect(result.outcome, WidgetFeedOutcome.superseded);
      expect(store.read()!.accountKey, previous.accountKey);
    },
  );

  test(
    'network revision change during generation cannot publish old route',
    () async {
      var revision = const NetworkRevision(0, networkIdentity: 'wifi-a');
      final (container, loader, store, transports) = await _makeWorld(
        networkRevision: () => revision,
      );
      addTearDown(container.dispose);
      expect((await loader.load()).written, isTrue);
      final previous = store.read()!;
      transports._firstCoverStarted = false;
      transports.beforeFirstCover = () async {
        revision = const NetworkRevision(1, networkIdentity: 'wifi-b');
      };

      final result = await loader.load();
      expect(result.outcome, WidgetFeedOutcome.superseded);
      expect(store.read()!.generatedAtMs, previous.generatedAtMs);
    },
  );

  test('oversize cover is rejected as transient', () async {
    final (container, loader, _, transports) = await _makeWorld();
    addTearDown(container.dispose);
    transports.coverBytes = List.filled(widgetImageMaxBytes + 1, 1);
    final result = await loader.load();
    expect(result.outcome, WidgetFeedOutcome.transientFailure);
  });

  test(
    'account revision from credential revision lands in the snapshot',
    () async {
      final (container, loader, store, _) = await _makeWorld();
      addTearDown(container.dispose);
      await loader.load();
      expect(store.read()!.accountKey, hasLength(16));
      expect(store.read()!.accountKey, isNot(contains('100')));
    },
  );
}
