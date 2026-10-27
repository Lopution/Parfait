import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/network/data_worker.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/illust/illust_snapshot_codec.dart';
import 'package:parfait/core/novel/novel_ranking_feed_controller.dart';
import 'package:parfait/core/novel/novel_repository.dart';
import 'package:parfait/core/novel/novel_store.dart';
import 'package:parfait/core/paging/feed_database.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/paging/paged_feed_controller.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

/// Minimal entity payload in the NovelSnapshotCodec schema.
Map<String, Object?> _novelSnapshotJson(int id) => {
  'id': id,
  'title': 'snapshot novel $id',
  'caption': 'snap caption',
  'text_length': 500,
  'user': {
    'id': 7,
    'name': 'snap-author',
    'account': 'snap',
    'profile_image_url': null,
    'is_followed': null,
    'is_muted': false,
    'visible': true,
  },
  'tags': [
    {'name': 'tag$id', 'translated_name': null},
  ],
  'series_id': null,
  'series_title': null,
  'cover_image_url': 'https://i.pximg.net/$id/c.png',
  'restrict': 0,
  'x_restrict': 0,
  'is_original': false,
  'is_bookmarked': false,
  'total_bookmarks': 5,
  'total_view': 9,
  'total_comments': 0,
  'visible': true,
  'is_muted': false,
  'is_mypixiv_only': false,
  'is_x_restricted': false,
  'novel_ai_type': 0,
  'create_date': '2026-09-01',
};

/// Snapshot reads wait on [reads].
class _HeldSnapshotStore extends FeedSnapshotStore {
  _HeldSnapshotStore(FeedDatabase database) : super(database: database);

  Completer<void> reads = Completer<void>()..complete();

  @override
  Future<FeedSnapshot?> read(
    String accountId,
    String feedKey, {
    Duration maxAge = FeedSnapshotStore.maxAge,
  }) async {
    await reads.future;
    return super.read(accountId, feedKey, maxAge: maxAge);
  }
}

class _World {
  _World(this.container, this.fixture, this.database, this.directory);
  final ProviderContainer container;
  final NovelRankingFixture fixture;
  final FeedDatabase database;
  final Directory directory;

  _HeldSnapshotStore get snapshots =>
      container.read(feedSnapshotStoreProvider) as _HeldSnapshotStore;

  Future<void> dispose() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  }
}

Future<_World> _makeWorld() async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final fixture = NovelRankingFixture();
  final directory = await Directory.systemTemp.createTemp('pixiv-feeds-test-');
  final database = FeedDatabase(
    factory: databaseFactoryFfi,
    databasePath: path.join(directory.path, 'feeds.db'),
  );
  final container = await signedInApiContainer(
    fixture.client(),
    others: const [Account(id: '200', userId: 200, name: 'b')],
    overrides: [
      feedSnapshotStoreProvider.overrideWithValue(_HeldSnapshotStore(database)),
      // Snapshot writes encode inline so a test can await them; the
      // isolate round trip is data_worker_test's.
      dataWorkerProvider.overrideWithValue(const InlineDataWorker()),
    ],
  );
  return _World(container, fixture, database, directory);
}

void main() {
  setUpAll(sqfliteFfiInit);

  final provider = novelRankingFeedProvider((
    mode: NovelRankingMode.day,
    date: null,
  ));
  const feedKey = 'novel-ranking:day';

  test('successful first load persists a snapshot row', () async {
    final world = await _makeWorld();
    addTearDown(world.dispose);

    final state = await world.container.read(provider.future);
    expect(state.ids, [1, 2]);
    await pumpEventQueue();

    final snapshot = await world.snapshots.read('100', feedKey);
    expect(snapshot, isNotNull);
    expect(snapshot!.ids, [1, 2]);
    expect(snapshot.cursor, contains('offset=30'));
    final novels = snapshot.entities['novel']! as Map<String, Object?>;
    expect(novels.keys.toSet(), {'1', '2'});
  });

  test('cold start renders the snapshot before the network answers', () async {
    final world = await _makeWorld();
    addTearDown(world.dispose);
    await world.snapshots.write(
      '100',
      feedKey,
      ids: const [10, 11],
      entities: {
        'novel': {'10': _novelSnapshotJson(10), '11': _novelSnapshotJson(11)},
      },
      cursor:
          'https://app-api.pixiv.net/v1/novel/ranking'
          '?filter=for_android&mode=day&offset=77',
    );

    // The build future resolves with restored content — no fetch happened
    // yet for this generation.
    final restored = await world.container.read(provider.future);
    expect(restored.ids, [10, 11]);
    expect(restored.initialPhase, FeedPhase.idle);
    expect(restored.exhausted, isFalse);

    // Restored entities are readable through the shared novel store.
    final restoredNovel = world.container.read(novelStoreProvider)[10];
    expect(restoredNovel, isNotNull);
    expect(restoredNovel!.title, 'snapshot novel 10');
    expect(restoredNovel.contentAvailable, isFalse);
    expect(restoredNovel.totalBookmarks, 5);

    // The scheduled background refresh replaces the snapshot with live data.
    await pumpEventQueue();
    expect(world.fixture.requests, hasLength(1));
    final state = world.container.read(provider).value!;
    expect(state.ids, [1, 2]);
  });

  test('restored cursor continues pagination from the snapshot', () async {
    final world = await _makeWorld();
    addTearDown(world.dispose);
    await world.snapshots.write(
      '100',
      feedKey,
      ids: const [10],
      entities: {
        'novel': {'10': _novelSnapshotJson(10)},
      },
      cursor:
          'https://app-api.pixiv.net/v1/novel/ranking'
          '?filter=for_android&mode=day&offset=77',
    );

    final restored = await world.container.read(provider.future);
    expect(restored.ids, [10]);
    // Cancel the scheduled background refresh so the loadMore assertion
    // observes the restored cursor instead of a refetched one.
    world.container.read(provider.notifier).cancel();
    await world.container.read(provider.notifier).loadMore();
    await pumpEventQueue();

    expect(world.fixture.requests, isNotEmpty);
    expect(world.fixture.requests.last.queryParameters['offset'], '77');
  });

  test('snapshots from another account are not restored', () async {
    final world = await _makeWorld();
    addTearDown(world.dispose);
    await world.snapshots.write(
      'other-account',
      feedKey,
      ids: const [10],
      entities: {
        'novel': {'10': _novelSnapshotJson(10)},
      },
    );

    final state = await world.container.read(provider.future);
    expect(state.ids, [1, 2]);
    expect(world.container.read(novelStoreProvider)[10], isNull);
  });

  test('a snapshot read landing after a switch restores nothing', () async {
    final world = await _makeWorld();
    addTearDown(world.dispose);
    await world.snapshots.write(
      '100',
      feedKey,
      ids: const [10],
      entities: {
        'novel': {'10': _novelSnapshotJson(10)},
      },
    );
    final reads = world.snapshots.reads = Completer<void>();
    world.container.listen(provider, (_, _) {});
    final accounts = world.container.read(accountStoreProvider.notifier);
    await accounts.switchAccount('200');
    world.container.read(novelStoreProvider);
    reads.complete();
    await pumpEventQueue();

    expect(world.container.read(novelStoreProvider)[10], isNull);
    expect(world.container.read(provider).value!.ids, [1, 2]);
    expect(world.fixture.requests, hasLength(1), reason: 'B\'s load only');
  });

  test('a snapshot without the feed entity payload is ignored', () async {
    final world = await _makeWorld();
    addTearDown(world.dispose);
    await world.snapshots.write(
      '100',
      feedKey,
      ids: const [10],
      entities: {
        'illust': {
          '10': {'id': 10},
        },
      },
    );

    final state = await world.container.read(provider.future);
    expect(state.ids, [1, 2]);
  });

  test('IllustSnapshotCodec round-trips through the shared store', () async {
    final world = await _makeWorld();
    addTearDown(world.dispose);
    final refProvider = Provider<Ref>((ref) => ref);
    final ref = world.container.read(refProvider);

    world.container.read(illustStoreProvider).mergeAll([
      parseIllust(illustJson(5)),
      parseIllust(illustJson(6)),
    ]);

    const codec = IllustSnapshotCodec();
    const ids = [5, 6, 999];
    final entities = codec.lookupEntities(ref, ids);
    expect(entities.keys.toSet(), {5, 6});
    final encoded = encodeFeedSnapshot((
      codec: codec,
      ids: ids,
      entities: entities,
    ));
    expect(jsonDecode(encoded.ids), ids);
    final payload =
        (jsonDecode(encoded.entities) as Map<String, Object?>)['illust']!
            as Map<String, Object?>;
    expect(payload.keys.toSet(), {'5', '6'});

    // Drop the live entities, then restore through the codec.
    world.container.read(illustStoreProvider).clear();
    final restored = codec.restoreEntities(ref, const [5, 6], payload);
    expect(restored, [5, 6]);
    expect(world.container.read(illustStoreProvider).get(5)?.id, 5);
    expect(world.container.read(illustStoreProvider).get(6)?.id, 6);
  });
}
