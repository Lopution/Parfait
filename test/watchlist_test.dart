import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/actionqueue/action_bootstrap.dart';
import 'package:parfait/core/actionqueue/action_models.dart';
import 'package:parfait/core/actionqueue/action_store.dart';
import 'package:parfait/core/mutation/mutation_models.dart';
import 'package:parfait/core/watchlist/watchlist_actions.dart';
import 'package:parfait/core/watchlist/watchlist_feed_controller.dart';
import 'package:parfait/core/watchlist/watchlist_models.dart';
import 'package:parfait/core/watchlist/watchlist_repository.dart';
import 'package:parfait/core/watchlist/watchlist_store.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

class _Fixture {
  final requests = <http.Request>[];
  final failures = <String, Object>{};
  final statuses = <String, int>{};
  Map<String, dynamic>? watchlistBody;

  String _key(Uri url) => url.path.contains('/novel') ? 'novel' : 'manga';

  http.Client build() => MockClient((request) async {
    requests.add(request);
    final key = _key(request.url);
    final failure = failures[key];
    if (failure != null) throw failure;
    final status = statuses[key] ?? 200;
    if (request.method == 'GET') {
      return jsonResponse(
        watchlistBody ??
            {
              'series': [
                {
                  'id': 9,
                  'title': 'Series Nine',
                  'user': {'id': 5, 'name': 'author'},
                  'latest_content_id': 777,
                  'last_published_content_datetime':
                      '2024-12-26T01:27:48+09:00',
                  'published_content_count': 3,
                  'url': 'https://i.pximg.net/c/x.jpg',
                },
              ],
              'next_url': null,
            },
        status,
      );
    }
    return jsonResponse({'is_success': status == 200}, status);
  });
}

class _World {
  _World(this.container, this.fixture, this.store);
  final ProviderContainer container;
  final _Fixture fixture;
  final InMemoryActionStore store;
}

Future<_World> _makeWorld({
  _Fixture? fixture,
  InMemoryActionStore? store,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final resolvedFixture = fixture ?? _Fixture();
  final resolvedStore = store ?? InMemoryActionStore();
  final container = await signedInApiContainer(
    resolvedFixture.build(),
    overrides: [actionStoreProvider.overrideWithValue(resolvedStore)],
  );
  return _World(container, resolvedFixture, resolvedStore);
}

const _mangaKey = WatchlistKey(WatchlistType.manga, 9);
const _novelKey = WatchlistKey(WatchlistType.novel, 21);

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  group('repository', () {
    test('fetches the manga watchlist and parses entries', () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);

      final page = await world.container
          .read(watchlistRepositoryProvider)
          .fetchWatchlist(WatchlistType.manga);

      expect(page.entries, hasLength(1));
      final entry = page.entries.single;
      expect(entry.id, 9);
      expect(entry.title, 'Series Nine');
      expect(entry.userName, 'author');
      expect(entry.latestContentId, 777);
      expect(entry.publishedContentCount, 3);
      expect(entry.coverUrl, 'https://i.pximg.net/c/x.jpg');
      expect(page.nextUrl, isNull);
      expect(world.fixture.requests.single.url.path, '/v1/watchlist/manga');
    });

    test('the last page ends the feed', () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      world.fixture.watchlistBody = {
        'series': <Object>[],
        'next_url': 'https://app-api.pixiv.net/v1/watchlist/manga?offset=30',
      };
      final feed = watchlistFeedProvider(WatchlistType.manga);
      await world.container.read(feed.future);
      // The default page carries no next_url.
      world.fixture.watchlistBody = null;
      for (var i = 0; i < 2; i++) {
        await world.container.read(feed.notifier).loadMore();
      }
      expect(world.container.read(feed).value!.hasMore, isFalse);
      expect(world.fixture.requests, hasLength(2));
    });

    test('rejects a next_url that points at a different endpoint', () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      world.fixture.watchlistBody = <String, dynamic>{
        'series': <Object?>[],
        'next_url': 'https://app-api.pixiv.net/v1/illust/series?offset=1',
      };

      expect(
        () => world.container
            .read(watchlistRepositoryProvider)
            .fetchWatchlist(WatchlistType.manga, cursor: 'next'),
        throwsA(isA<Exception>()),
      );
      // Hand the server a foreign cursor directly.
      expect(
        world.container
            .read(watchlistRepositoryProvider)
            .validateCursor(
              WatchlistType.manga,
              cursor: 'https://app-api.pixiv.net/v1/watchlist/novel?offset=1',
            ),
        isFalse,
      );
    });

    test('add and delete post series_id to the typed endpoint', () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      final repository = world.container.read(watchlistRepositoryProvider);

      await repository.add(_novelKey);
      await repository.delete(_mangaKey);

      expect(world.fixture.requests[0].url.path, '/v1/watchlist/novel/add');
      expect(
        Uri.splitQueryString(world.fixture.requests[0].body)['series_id'],
        '21',
      );
      expect(world.fixture.requests[1].url.path, '/v1/watchlist/manga/delete');
      expect(
        Uri.splitQueryString(world.fixture.requests[1].body)['series_id'],
        '9',
      );
    });
  });

  group('store and actions', () {
    test('toggle add confirms the entry', () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);

      await world.container.read(watchlistActionsProvider).toggle(_mangaKey);

      final entry = world.container.read(watchlistStoreProvider)[_mangaKey]!;
      expect(entry.added, isTrue);
      expect(entry.isPending, isFalse);
      expect(world.fixture.requests.single.url.path, '/v1/watchlist/manga/add');
    });

    test('toggle on a watched series deletes it', () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      world.container
          .read(watchlistStoreProvider.notifier)
          .observeRemote(_mangaKey, added: true);

      await world.container.read(watchlistActionsProvider).toggle(_mangaKey);

      expect(
        world.fixture.requests.single.url.path,
        '/v1/watchlist/manga/delete',
      );
      expect(
        world.container.read(watchlistStoreProvider)[_mangaKey]!.added,
        isFalse,
      );
    });

    test('business rejection fails visibly without queueing', () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      world.fixture.statuses['manga'] = 403;

      final toggle = world.container
          .read(watchlistActionsProvider)
          .toggle(_mangaKey);
      expect(
        world.container.read(watchlistStoreProvider)[_mangaKey]!.shown,
        isTrue,
        reason: 'flipped on the tap',
      );
      await toggle;

      final entry = world.container.read(watchlistStoreProvider)[_mangaKey]!;
      expect(entry.isPending, isFalse);
      expect(entry.shown, isFalse, reason: 'rolled back');
      expect(entry.status, MutationStatus.failed);
      expect(await world.store.listFor('100'), isEmpty);
    });

    test('a second tap in flight follows up after the first', () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      final actions = world.container.read(watchlistActionsProvider);

      final first = actions.toggle(_mangaKey);
      await actions.toggle(_mangaKey);
      await first;

      expect(world.fixture.requests.map((r) => r.url.path), [
        '/v1/watchlist/manga/add',
        '/v1/watchlist/manga/delete',
      ]);
      final entry = world.container.read(watchlistStoreProvider)[_mangaKey]!;
      expect(entry.added, isFalse);
      expect(entry.wish, isNull);
    });
  });

  group('offline replay', () {
    test('connectivity failure queues the add and keeps pending', () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      world.fixture.failures['manga'] = http.ClientException('offline');

      await world.container.read(watchlistActionsProvider).toggle(_mangaKey);

      final entry = world.container.read(watchlistStoreProvider)[_mangaKey]!;
      expect(entry.isQueued, isTrue);
      expect(entry.added, isFalse);
      final rows = await world.store.listFor('100');
      expect(rows.single.type, ActionTypes.watchlistAdd);
      expect(rows.single.dedupeKey, 'watchlist:manga:9');
    });

    test('a tap on a queued watch takes the intent back', () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      world.fixture.failures['manga'] = http.ClientException('offline');
      final actions = world.container.read(watchlistActionsProvider);

      await actions.toggle(_mangaKey);
      await actions.toggle(_mangaKey);

      final entry = world.container.read(watchlistStoreProvider)[_mangaKey]!;
      expect(entry.shown, isFalse);
      expect(entry.isPending, isFalse);
      expect(await world.store.listFor('100'), isEmpty);
    });

    test('replay confirms the still-pending watch', () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      world.fixture.failures['novel'] = http.ClientException('offline');

      await world.container.read(watchlistActionsProvider).toggle(_novelKey);
      world.fixture.failures.remove('novel');
      await world.container.read(actionQueueProvider).drain('100');

      expect(world.fixture.requests.last.url.path, '/v1/watchlist/novel/add');
      final entry = world.container.read(watchlistStoreProvider)[_novelKey]!;
      expect(entry.added, isTrue);
      expect(entry.isPending, isFalse);
      expect(await world.store.listFor('100'), isEmpty);
    });

    test(
      'add-then-delete across a restart coalesces to the last intent',
      () async {
        final store = InMemoryActionStore();
        final fixture = _Fixture()
          ..failures['manga'] = http.ClientException('offline');

        final first = await _makeWorld(fixture: fixture, store: store);
        await first.container.read(watchlistActionsProvider).toggle(_mangaKey);
        first.container.dispose();

        final second = await _makeWorld(fixture: fixture, store: store);
        addTearDown(second.container.dispose);
        second.container
            .read(watchlistStoreProvider.notifier)
            .observeRemote(_mangaKey, added: true);
        await second.container.read(watchlistActionsProvider).toggle(_mangaKey);

        final rows = await store.listFor('100');
        expect(rows, hasLength(1));
        expect(rows.single.type, ActionTypes.watchlistDelete);

        fixture.failures.remove('manga');
        await second.container.read(actionQueueProvider).drain('100');
        expect(
          second.fixture.requests.last.url.path,
          '/v1/watchlist/manga/delete',
        );
      },
    );
  });

  group('read cursor', () {
    test('markSeen only moves the cursor forward', () async {
      final world = await _makeWorld();
      addTearDown(world.container.dispose);
      final cursor = world.container.read(watchlistReadCursorProvider);

      expect(await cursor.read('100', _mangaKey), isNull);
      await cursor.markSeen('100', _mangaKey, 700);
      await cursor.markSeen('100', _mangaKey, 650);
      expect(await cursor.read('100', _mangaKey), 700);
      await cursor.markSeen('100', _mangaKey, 800);
      expect(await cursor.read('100', _mangaKey), 800);

      // Cursors are scoped per account, type and series.
      expect(await cursor.read('100', _novelKey), isNull);
      expect(await cursor.read('other', _mangaKey), isNull);
    });
  });
}
