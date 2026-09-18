import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/actionqueue/action_bootstrap.dart';
import 'package:pixiv_func/core/actionqueue/action_models.dart';
import 'package:pixiv_func/core/actionqueue/action_store.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/bookmark/bookmark_actions.dart';
import 'package:pixiv_func/core/bookmark/bookmark_models.dart';
import 'package:pixiv_func/core/bookmark/bookmark_store.dart';
import 'package:pixiv_func/core/mutation/mutation_models.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/user/follow_actions.dart';
import 'package:pixiv_func/core/user/follow_store.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

/// Records every mutation call; per-path failures simulate the offline
/// window and per-path statuses simulate business rejections.
class _MutationFixture {
  final requests = <http.Request>[];
  final failures = <String, Object>{};
  final statuses = <String, int>{};

  String _key(Uri url) {
    final path = url.path;
    if (path.contains('follow')) return 'follow';
    if (path.contains('novel')) return 'novel';
    return 'illust';
  }

  http.Client build() => MockClient((request) async {
    requests.add(request);
    final key = _key(request.url);
    final failure = failures[key];
    if (failure != null) throw failure;
    final status = statuses[key] ?? 200;
    return http.Response(
      jsonEncode({'is_success': status == 200}),
      status,
      headers: {'content-type': 'application/json'},
    );
  });
}

class _World {
  _World(this.container, this.fixture, this.store);
  final ProviderContainer container;
  final _MutationFixture fixture;
  final InMemoryActionStore store;
}

Future<_World> _makeWorld({
  _MutationFixture? fixture,
  InMemoryActionStore? store,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final resolvedFixture = fixture ?? _MutationFixture();
  final resolvedStore = store ?? InMemoryActionStore();
  final credentials = FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 'tester')],
          currentId: '100',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async {
            fail('refresh should not happen in action replay tests');
          }),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client not wired yet');
        return client;
      }),
      actionStoreProvider.overrideWithValue(resolvedStore),
    ],
  );
  final client = PixivHttpClient(
    client: resolvedFixture.build(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  return _World(container, resolvedFixture, resolvedStore);
}

const _illustKey = BookmarkKey(BookmarkEntityType.illust, 42);

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test(
    'offline bookmark add queues the intent and keeps the pending entry',
    () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      world.fixture.failures['illust'] = http.ClientException('offline');

      await world.container.read(bookmarkActionsProvider).toggle(_illustKey);

      final entry = world.container.read(bookmarkStoreProvider)[_illustKey]!;
      expect(entry.isPending, isTrue);
      expect(entry.bookmarked, isFalse, reason: 'confirmed value unchanged');
      expect(entry.error, isNull);

      final rows = await world.store.listFor('100');
      expect(rows, hasLength(1));
      expect(rows.single.type, ActionTypes.bookmarkAdd);
      expect(rows.single.dedupeKey, 'bookmark:illust:42');
    },
  );

  test('business rejection fails visibly without queueing', () async {
    final world = await _makeWorld();
    addTearDown(world.container.dispose);
    world.fixture.statuses['illust'] = 403;

    await world.container.read(bookmarkActionsProvider).toggle(_illustKey);

    final entry = world.container.read(bookmarkStoreProvider)[_illustKey]!;
    expect(entry.isPending, isFalse);
    expect(entry.error, isNotNull);
    expect(await world.store.listFor('100'), isEmpty);
  });

  test(
    'replay commits the still-pending bookmark through the repository',
    () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      world.fixture.failures['illust'] = http.ClientException('offline');

      await world.container.read(bookmarkActionsProvider).toggle(_illustKey);
      expect(world.fixture.requests, hasLength(1));

      // Connectivity returns: the queued row replays the same add call and
      // the pending entry confirms.
      world.fixture.failures.remove('illust');
      final queue = world.container.read(actionQueueProvider);
      await queue.drain('100');

      expect(world.fixture.requests, hasLength(2));
      expect(world.fixture.requests.last.url.path, '/v2/illust/bookmark/add');
      final entry = world.container.read(bookmarkStoreProvider)[_illustKey]!;
      expect(entry.bookmarked, isTrue);
      expect(entry.isPending, isFalse);
      expect(await world.store.listFor('100'), isEmpty);
      expect(queue.telemetry.replayed, 1);
    },
  );

  test('bookmark add replay carries restrict and the full tag set', () async {
    final world = await _makeWorld();
    addTearDown(world.container.dispose);
    world.fixture.failures['illust'] = http.ClientException('offline');

    await world.container
        .read(bookmarkActionsProvider)
        .addWithRestrict(
          _illustKey,
          BookmarkRestrict.private,
          tags: const ['tag-a', 'tag-b'],
        );
    world.fixture.failures.remove('illust');
    await world.container.read(actionQueueProvider).drain('100');

    final body = Uri.splitQueryString(world.fixture.requests.last.body);
    expect(body['restrict'], 'private');
    expect(body['tags[]'], 'tag-a tag-b');
  });

  test('restart merges a replayed bookmark without a pending op', () async {
    final store = InMemoryActionStore();
    final fixture = _MutationFixture()
      ..failures['illust'] = http.ClientException('offline');

    // Session A: the add fails offline and is queued.
    final first = await _makeWorld(fixture: fixture, store: store);
    await first.container.read(bookmarkActionsProvider).toggle(_illustKey);
    first.container.dispose();

    // Session B: a fresh container has no pending op — the replayed
    // confirmation merges like a remote snapshot.
    fixture.failures.remove('illust');
    final second = await _makeWorld(fixture: fixture, store: store);
    addTearDown(second.container.dispose);
    await second.container.read(actionQueueProvider).drain('100');

    final entry = second.container.read(bookmarkStoreProvider)[_illustKey]!;
    expect(entry.bookmarked, isTrue);
    expect(entry.isPending, isFalse);
    expect(entry.status, MutationStatus.idle);
  });

  test(
    'add-then-delete across a restart coalesces to the last intent',
    () async {
      final store = InMemoryActionStore();
      final fixture = _MutationFixture()
        ..failures['illust'] = http.ClientException('offline');

      // Session A queues the add while offline.
      final first = await _makeWorld(fixture: fixture, store: store);
      await first.container.read(bookmarkActionsProvider).toggle(_illustKey);
      first.container.dispose();

      // Session B (still offline) deletes the same target: the pending row
      // is replaced, not appended.
      final second = await _makeWorld(fixture: fixture, store: store);
      addTearDown(second.container.dispose);
      second.container
          .read(bookmarkStoreProvider.notifier)
          .observeRemote(_illustKey, bookmarked: true, snapshotRevision: 0);
      await second.container.read(bookmarkActionsProvider).toggle(_illustKey);

      var rows = await store.listFor('100');
      expect(rows, hasLength(1));
      expect(rows.single.type, ActionTypes.bookmarkDelete);

      // Recovery: only the delete replays — the add was coalesced away.
      fixture.failures.remove('illust');
      await second.container.read(actionQueueProvider).drain('100');
      expect(
        second.fixture.requests.last.url.path,
        '/v1/illust/bookmark/delete',
      );
      rows = await store.listFor('100');
      expect(rows, isEmpty);
    },
  );

  test(
    'offline follow add queues and replays into a confirmed follow',
    () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      world.fixture.failures['follow'] = http.ClientException('offline');

      await world.container.read(followActionsProvider).toggle(7);

      var entry = world.container.read(followStoreProvider)[7]!;
      expect(entry.isPending, isTrue);
      expect(entry.followed, isFalse);
      final rows = await world.store.listFor('100');
      expect(rows.single.type, ActionTypes.followAdd);
      expect(rows.single.dedupeKey, 'follow:7');

      world.fixture.failures.remove('follow');
      await world.container.read(actionQueueProvider).drain('100');

      expect(world.fixture.requests.last.url.path, '/v1/user/follow/add');
      entry = world.container.read(followStoreProvider)[7]!;
      expect(entry.followed, isTrue);
      expect(entry.isPending, isFalse);
    },
  );

  test(
    'offline unfollow queues and replays into a confirmed unfollow',
    () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      world.container
          .read(followStoreProvider.notifier)
          .observeRemote(7, followed: true, snapshotRevision: 0);
      world.fixture.failures['follow'] = http.ClientException('offline');

      await world.container.read(followActionsProvider).toggle(7);
      world.fixture.failures.remove('follow');
      await world.container.read(actionQueueProvider).drain('100');

      expect(world.fixture.requests.last.url.path, '/v1/user/follow/delete');
      final entry = world.container.read(followStoreProvider)[7]!;
      expect(entry.followed, isFalse);
      expect(entry.isPending, isFalse);
    },
  );

  test('queue rows never cross the account boundary', () async {
    final world = await _makeWorld();
    addTearDown(world.container.dispose);
    world.fixture.failures['illust'] = http.ClientException('offline');
    await world.container.read(bookmarkActionsProvider).toggle(_illustKey);

    // Draining a different owner must not touch account 100's row.
    await world.container.read(actionQueueProvider).drain('other');
    expect(await world.store.listFor('100'), hasLength(1));
    expect(world.fixture.requests, hasLength(1));
  });
}
