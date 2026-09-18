import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/illust/illust_snapshot_codec.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/novel/novel_ranking_feed_controller.dart';
import 'package:pixiv_func/core/novel/novel_repository.dart';
import 'package:pixiv_func/core/novel/novel_store.dart';
import 'package:pixiv_func/core/paging/feed_database.dart';
import 'package:pixiv_func/core/paging/feed_snapshot_store.dart';
import 'package:pixiv_func/core/paging/paged_feed_controller.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

Map<String, dynamic> _novelJson(int id) => {
  'id': id,
  'title': 'novel $id',
  'caption': '',
  'restrict': 0,
  'x_restrict': 0,
  'image_urls': {'medium': 'https://i.pximg.net/$id/m.png'},
  'tags': <Object>[],
  'text_length': 1200,
  'user': {
    'id': 99,
    'name': 'author',
    'account': 'author',
    'profile_image_urls': {'medium': 'https://i.pximg.net/u.png'},
  },
  'is_bookmarked': false,
  'visible': true,
};

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

class _RankingFixture {
  final requests = <Uri>[];

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    final isFirst = request.url.queryParameters['offset'] == null;
    final start = isFirst ? 1 : 3;
    return http.Response(
      jsonEncode({
        'novels': [for (var id = start; id < start + 2; id++) _novelJson(id)],
        'next_url': isFirst
            ? 'https://app-api.pixiv.net/v1/novel/ranking'
                  '?filter=for_android&mode=day&offset=30'
            : null,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

class _World {
  _World(this.container, this.fixture, this.database, this.directory);
  final ProviderContainer container;
  final _RankingFixture fixture;
  final FeedDatabase database;
  final Directory directory;

  FeedSnapshotStore get snapshots => container.read(feedSnapshotStoreProvider);

  Future<void> dispose() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  }
}

Future<_World> _makeWorld() async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final fixture = _RankingFixture();
  final directory = await Directory.systemTemp.createTemp('pixiv-feeds-test-');
  final database = FeedDatabase(
    factory: databaseFactoryFfi,
    databasePath: path.join(directory.path, 'feeds.db'),
  );
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
            fail('refresh should not happen in snapshot fixture');
          }),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client not wired yet');
        return client;
      }),
      feedSnapshotStoreProvider.overrideWithValue(
        FeedSnapshotStore(database: database),
      ),
    ],
  );
  final client = PixivHttpClient(
    client: fixture.client(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  return _World(container, fixture, database, directory);
}

void main() {
  setUpAll(sqfliteFfiInit);

  final provider = novelRankingFeedProvider(NovelRankingMode.day);
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
    final encoded = codec.encodeEntities(ref, const [5, 6, 999]);
    expect(encoded.keys.toSet(), {'5', '6'});

    // Drop the live entities, then restore through the codec.
    world.container.read(illustStoreProvider).clear();
    final restored = codec.restoreEntities(ref, const [5, 6], encoded);
    expect(restored, [5, 6]);
    expect(world.container.read(illustStoreProvider).get(5)?.id, 5);
    expect(world.container.read(illustStoreProvider).get(6)?.id, 6);
  });
}
