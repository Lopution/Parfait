import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/comments/comment_translation.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/history/history_models.dart';
import 'package:parfait/core/history/history_repository.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/localnovel/local_novel_database.dart';
import 'package:parfait/core/localnovel/local_novel_repository.dart';
import 'package:parfait/core/watchlater/watch_later_database.dart';
import 'package:parfait/core/watchlater/watch_later_repository.dart';
import 'package:parfait/core/watchlater/watch_later_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:parfait/core/illust/illust_detail_controller.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/network/http_client_providers.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/platform/accessibility.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../helpers/connectivity_channels.dart';
import '../helpers/download_world.dart';
import '../helpers/fake_account.dart';
import '../helpers/history_world.dart';
import '../helpers/illust_fixtures.dart';
import '../helpers/image_network.dart';
import '../helpers/memory_feed_snapshot_store.dart';
import '../helpers/series_world.dart';
import '../helpers/settings_world.dart';
import '../helpers/test_preferences.dart';
import 'review_fixtures.dart';

/// One API response for a path the review world serves.
typedef ReviewResponder = FutureOr<http.Response> Function(Uri url);

/// Builds a 200 JSON response.
ReviewResponder reviewJson(Object? body) =>
    (_) async => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json'},
    );

/// Never answers — the loading state.
ReviewResponder reviewLoading() =>
    (_) => Completer<http.Response>().future;

/// An empty page of [key] (`illusts`, `novels`, `user_previews`, ...).
ReviewResponder reviewEmpty(String key) =>
    reviewJson({key: const <Object?>[], 'next_url': null});

/// An immediate API failure — the error state.
ReviewResponder reviewError([int status = 500]) =>
    (_) async => http.Response('review error', status);

/// All remote data for the review harness. API calls route through one
/// `PixivHttpClient` whose dispatch table serves real envelopes; images come
/// from generated PNGs; local stores (history, downloads, snapshots, prefs)
/// run their real implementations on in-memory or temp backends.
class ReviewWorld {
  ReviewWorld._(this.container, this.responders);

  /// The container driving `UncontrolledProviderScope` in the scene.
  final ProviderContainer container;

  /// Path → responder. Scenes replace entries to flip a page's state:
  /// empty list, `reviewError()`, or `reviewGated(completer)`.
  final Map<String, ReviewResponder> responders;

  /// The world [setup] describes: by default one signed-in account, empty
  /// local stores, and content payloads for every API path the app calls.
  ///
  /// Real IO (temp dirs, sqlite ffi) — call inside `tester.runAsync`.
  static Future<ReviewWorld> open([
    ReviewSetup setup = const ReviewSetup(),
  ]) async {
    final ReviewSetup(
      :api,
      :history,
      :watchlater,
      :localNovels,
      :downloadGroups,
      :downloadSingles,
      :signedIn,
      :touchExploration,
    ) = setup;
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
    PackageInfo.setMockInitialValues(
      appName: 'Parfait',
      packageName: 'io.github.lopution.parfait',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final responders = _defaultResponders()..addAll(api);

    answerConnectivityChannels();

    final transport = FakeTransport();
    for (var i = 0; i < 8; i++) {
      transport.responses.add(
        ScriptedResponse(
          contentLength: 3,
          chunks: [
            [1, 2, 3],
          ],
        ),
      );
    }
    final sinks = MemorySinkFactory();
    final manager = DownloadManager(transport: transport, sinkFactory: sinks);
    for (var i = 0; i < downloadSingles; i++) {
      manager.submit(downloadRequest(100 + i, title: 'download $i'));
    }
    for (var g = 0; g < downloadGroups; g++) {
      manager.submitGroup([
        for (var i = 0; i < 3; i++) downloadRequest(200 + 10 * g + i),
      ]);
    }
    // Every local store opens here, inside runAsync: sqflite's reply port
    // binds to the zone that opens the database, and one first opened by
    // a page in the fake zone never hears back from its close.
    final tmp = Directory.systemTemp.createTempSync('review-stores-');
    addTearDown(() => tmp.delete(recursive: true));
    final watchDb = WatchLaterDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${tmp.path}/watchlater.db',
    );
    final novelDb = LocalNovelDatabase(
      factory: databaseFactoryFfi,
      databasePath: '${tmp.path}/localnovels.db',
    );
    await (watchDb.database, novelDb.database).wait;
    addTearDown(() => (watchDb.close(), novelDb.close()).wait);
    final watchRepo = WatchLaterRepository(database: watchDb);
    for (var i = 0; i < watchlater; i++) {
      await watchRepo.add('100', parseIllust(reviewIllustJson(4000 + i)));
    }
    final novelRepo = LocalNovelRepository(database: novelDb);
    for (var i = 0; i < localNovels; i++) {
      await novelRepo.importBytes(
        fileName: 'local novel $i.txt',
        bytes: utf8.encode('local novel $i ' * 200),
        targetDir: tmp,
      );
    }

    final credentials = FakeCredentialStore();
    final signedInAccounts = [
      if (signedIn)
        for (var i = 0; i < setup.accounts; i++)
          Account(
            id: '${100 + i}',
            userId: 100 + i,
            name: i == 0 ? 'tester' : 'tester ${i + 1}',
          ),
    ];
    for (final (i, account) in signedInAccounts.indexed) {
      credentials.seed(
        account.id,
        Credential(
          accessToken: 'access-${i + 1}',
          refreshToken: 'refresh-${i + 1}',
        ),
      );
    }
    final metadata = FakeAccountMetadataRepository(
      accounts: signedInAccounts,
      currentId: signedInAccounts.firstOrNull?.id,
    );
    // pixivision's own CDN images bypass the app's image pipeline and load
    // through cached_network_image's global manager. Not restored: reading
    // the default would construct it, and it needs path_provider. Review
    // processes run nothing else.
    CachedNetworkImageProvider.defaultCacheManager = testImageCacheManager(
      _ReviewFileService(),
    );
    final pixivisionArticle = await File(
      'test/fixtures/pixivision/article_10943.html',
    ).readAsBytes();
    final clientRef = <PixivHttpClient?>[null];
    final historyRepo = await openHistoryRepository(history);

    final container = ProviderContainer(
      overrides: [
        ...accountProviderOverrides(
          credentialStore: credentials,
          metadataRepository: metadata,
        ),
        oauthServiceProvider.overrideWithValue(
          OAuthService(
            client: MockClient(
              (_) async => throw StateError('no token refresh in review'),
            ),
          ),
        ),
        pixivHttpClientProvider.overrideWith((ref) {
          final client = clientRef[0];
          if (client == null) {
            throw StateError('review client not wired yet');
          }
          return client;
        }),
        // Third-party HTML: every pixivision article is the captured real
        // page the article parser is tested against.
        thirdPartyHttpClientProvider.overrideWithValue(
          MockClient(
            (request) async => http.Response.bytes(
              pixivisionArticle,
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            ),
          ),
        ),
        // The detail page's page-dims web call stays unavailable, matching
        // detail_world's documented fallback path.
        illustDetailWebClientProvider.overrideWithValue(
          MockClient((_) async => http.Response('unavailable', 403)),
        ),
        feedSnapshotStoreProvider.overrideWithValue(MemoryFeedSnapshotStore()),
        historyRepositoryProvider.overrideWithValue(historyRepo),
        watchLaterRepositoryProvider.overrideWithValue(watchRepo),
        localNovelRepositoryProvider.overrideWithValue(novelRepo),
        downloadManagerProvider.overrideWithValue(manager),
        platformCapsProvider.overrideWithValue(
          const PlatformCaps(isAndroid: true),
        ),
        // The keystore is a platform channel.
        translationCredentialStoreProvider.overrideWithValue(
          FakeTranslationStore(),
        ),
        appAccessibilityProvider.overrideWithValue(
          _ReviewAccessibility(touchExploration),
        ),
        // Images: generated PNGs. Original files load through the legacy
        // cache chain, everything else through the real image worker.
        imageWorkerProvider.overrideWithValue(
          inProcessImageWorker(
            () => MockClient(
              (request) async => http.Response.bytes(
                ReviewImageBytes.forUrl('${request.url}'),
                200,
              ),
            ),
          ),
        ),
        pixivNetworkFactoryProvider.overrideWithValue(
          ScriptedImageNetwork(testImageCacheManager(_ReviewFileService())),
        ),
        ...setup.overrides,
      ],
    );
    clientRef[0] = PixivHttpClient(
      client: MockClient((request) async {
        final responder = responders[request.url.path];
        if (responder != null) return responder(request.url);
        return http.Response('review world has no ${request.url.path}', 404);
      }),
      accountStore: container.read(accountStoreProvider.notifier),
      credentialStore: credentials,
      oauthService: container.read(oauthServiceProvider),
    );
    await container.read(accountStoreProvider.future);
    addTearDown(container.dispose);
    return ReviewWorld._(container, responders);
  }
}

/// What a scene's world holds. Every field is a starting state the user's
/// phone can be in; [api] swaps single responders for empty, error or
/// gated pages.
class ReviewSetup {
  const ReviewSetup({
    this.api = const {},
    this.history = const [],
    this.watchlater = 0,
    this.localNovels = 0,
    this.downloadGroups = 0,
    this.downloadSingles = 0,
    this.signedIn = true,
    this.accounts = 1,
    this.touchExploration = false,
    this.overrides = const [],
  });

  final Map<String, ReviewResponder> api;
  final List<HistoryRecord> history;
  final int watchlater;
  final int localNovels;

  /// Three-item download groups and single downloads in the queue.
  final int downloadGroups;
  final int downloadSingles;

  final bool signedIn;

  /// Signed-in accounts; the first is current.
  final int accounts;

  /// TalkBack exploring by touch. Off is the user's usual state: GKD on,
  /// TalkBack off.
  final bool touchExploration;

  final List<Override> overrides;

  ReviewSetup copyWith({bool? touchExploration}) => ReviewSetup(
    api: api,
    history: history,
    watchlater: watchlater,
    localNovels: localNovels,
    downloadGroups: downloadGroups,
    downloadSingles: downloadSingles,
    signedIn: signedIn,
    accounts: accounts,
    touchExploration: touchExploration ?? this.touchExploration,
    overrides: overrides,
  );
}

/// The platform's accessibility channel, answering with a fixed
/// touch-exploration state and unscaled prompt timeouts.
class _ReviewAccessibility implements AppAccessibility {
  const _ReviewAccessibility(this.touchExploration);

  final bool touchExploration;

  @override
  Future<bool> isTouchExplorationEnabled() async => touchExploration;

  @override
  Stream<bool> touchExplorationChanges() => Stream.value(touchExploration);

  @override
  Future<int> recommendedTimeoutMillis(int baseMs, int contentFlags) async =>
      baseMs;
}

/// A file service that renders each URL into a deterministic generated PNG.
/// Colour bands keep cards recognisable on shots without shipped assets.
class _ReviewFileService extends FileService {
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async => _ReviewFileResponse(ReviewImageBytes.forUrl(url));
}

class _ReviewFileResponse implements FileServiceResponse {
  _ReviewFileResponse(this.bytes);

  final Uint8List bytes;

  @override
  Stream<List<int>> get content => Stream.value(bytes);

  @override
  int get contentLength => bytes.length;

  @override
  int get statusCode => 200;

  @override
  DateTime get validTill => DateTime.now().add(const Duration(days: 365));

  @override
  String? get eTag => '"review"';

  @override
  String get fileExtension => '.png';
}

/// Content payloads for every API path the routes call. Scenes swap single
/// entries for empty/error/gated states.
Map<String, ReviewResponder> _defaultResponders() {
  List<Map<String, dynamic>> illusts(int first, int count) => [
    for (var i = 0; i < count; i++)
      reviewIllustJson(
        first + i,
        bookmarked: i == 1,
        pageCount: i.isEven ? 1 : 3,
      ),
  ];
  List<Map<String, dynamic>> novels(int first, int count) => [
    for (var i = 0; i < count; i++) reviewNovelJson(first + i),
  ];
  List<Map<String, dynamic>> users(int first, int count) => [
    for (var i = 0; i < count; i++) reviewUserPreviewJson(first + i),
  ];
  final illustFeed = {'illusts': illusts(1000, 12), 'next_url': null};
  final novelFeed = {'novels': novels(2000, 10), 'next_url': null};
  final userFeed = {'user_previews': users(3000, 6), 'next_url': null};

  return {
    // Three pages, so scrolling reaches load-more like on a phone.
    '/v1/illust/recommended': (url) {
      final offset = int.parse(url.queryParameters['offset'] ?? '0');
      return reviewJson({
        'illusts': illusts(1000 + offset, 12),
        'next_url': offset < 24
            ? 'https://app-api.pixiv.net/v1/illust/recommended'
                  '?content_type=illust&filter=for_ios&offset=${offset + 12}'
            : null,
      })(url);
    },
    '/v1/illust/ranking': reviewJson(illustFeed),
    '/v1/illust/new': reviewJson(illustFeed),
    '/v2/illust/follow': reviewJson(illustFeed),
    '/v2/illust/mypixiv': reviewJson(illustFeed),
    '/v1/novel/recommended': reviewJson(novelFeed),
    '/v1/novel/ranking': reviewJson(novelFeed),
    '/v1/novel/new': reviewJson(novelFeed),
    '/v1/novel/follow': reviewJson(novelFeed),
    '/v1/novel/mypixiv': reviewJson(novelFeed),
    '/v1/illust/detail': (url) async => reviewJson({
      'illust': reviewIllustJson(
        int.parse(url.queryParameters['illust_id'] ?? '1000'),
        pageCount: 3,
        caption: [
          '作品说明文字，第一段较长，用来展示简介在收起状态下的截断效果，'
              '以及展开以后完整显示的样子。',
          '第二段：创作花絮与使用说明。',
          '第三段：<a href="https://www.pixiv.net/users/99">作者主页</a>',
          '第四段：感谢观看。',
          '第五段：欢迎收藏。',
        ].join('<br />'),
      ),
    })(url),
    '/v2/illust/related': reviewJson(illustFeed),
    '/v3/illust/comments': reviewJson({
      'comments': [for (var i = 1; i <= 4; i++) reviewCommentJson(i, 1)],
      'next_url': null,
    }),
    '/v3/novel/comments': reviewJson({
      'comments': [for (var i = 1; i <= 4; i++) reviewCommentJson(i, 1)],
      'next_url': null,
    }),
    '/v2/illust/comment/replies': reviewJson({
      'comments': [for (var i = 10; i <= 12; i++) reviewCommentJson(i, 1)],
      'next_url': null,
    }),
    '/v2/novel/comment/replies': reviewJson({
      'comments': [for (var i = 10; i <= 12; i++) reviewCommentJson(i, 1)],
      'next_url': null,
    }),
    '/v1/search/illust': reviewJson(illustFeed),
    '/v1/search/novel': reviewJson(novelFeed),
    '/v1/search/user': reviewJson(userFeed),
    '/v1/search/popular-preview/illust': reviewJson({
      'trend_tags': [for (var i = 0; i < 6; i++) reviewTrendTagJson(i)],
    }),
    '/v1/search/popular-preview/novel': reviewJson({
      'trend_tags': [for (var i = 0; i < 6; i++) reviewTrendTagJson(i)],
    }),
    '/v1/trending-tags/illust': reviewJson({
      'trend_tags': [for (var i = 0; i < 10; i++) reviewTrendTagJson(i)],
    }),
    '/v1/trending-tags/novel': reviewJson({
      'trend_tags': [for (var i = 0; i < 10; i++) reviewTrendTagJson(i)],
    }),
    '/v2/search/autocomplete': reviewJson({
      'tags': <Map<String, dynamic>>[
        {'name': 'girl', 'translated_name': '女の子'},
        {'name': 'cat'},
      ],
    }),
    '/v1/user/detail': (url) async => reviewJson(
      reviewUserDetailJson(int.parse(url.queryParameters['user_id'] ?? '99')),
    )(url),
    '/v1/user/illusts': reviewJson(illustFeed),
    '/v1/user/novels': reviewJson(novelFeed),
    '/v1/user/bookmarks/illust': reviewJson(illustFeed),
    '/v1/user/bookmarks/novel': reviewJson(novelFeed),
    '/v1/user/mypixiv': reviewJson(illustFeed),
    '/v1/user/following': reviewJson(userFeed),
    '/v1/user/follower': reviewJson(userFeed),
    '/v1/user/recommended': reviewJson(userFeed),
    '/v1/user/follow/detail': reviewJson({
      'follow_detail': {'restrict': 'public'},
    }),
    '/v1/user/illust-series': reviewJson({
      'illust_series_details': [
        seriesDetailJson(500),
        seriesDetailJson(501, workCount: 3, title: 'another'),
      ],
      'next_url': null,
    }),
    '/v1/user/bookmark-tags/illust': reviewJson({
      'bookmark_tags': [
        reviewBookmarkTagJson('风景'),
        reviewBookmarkTagJson('猫'),
      ],
    }),
    '/v1/user/bookmark-tags/novel': reviewJson({
      'bookmark_tags': [reviewBookmarkTagJson('长篇')],
    }),
    '/v1/mypixiv/all': reviewJson(userFeed),
    '/v1/illust/series': (url) async => reviewJson({
      'illust_series_detail': seriesDetailJson(
        int.parse(url.queryParameters['illust_series_id'] ?? '500'),
      ),
      'illust_series_first_illust': reviewIllustJson(600),
      'illust_series_latest_illust': reviewIllustJson(611),
      'illusts': illusts(600, 12),
      'next_url': null,
    })(url),
    // Works outside a series, like most.
    '/v1/illust-series/illust': reviewJson(const {
      'illust_series_detail': null,
      'illust_series_context': null,
    }),
    '/v2/novel/detail': (url) async => reviewJson(
      reviewNovelDetailJson(
        int.parse(url.queryParameters['novel_id'] ?? '2000'),
      ),
    )(url),
    '/webview/v2/novel': (url) async => http.Response.bytes(
      utf8.encode(
        reviewNovelWebviewHtml(int.parse(url.queryParameters['id'] ?? '2000')),
      ),
      200,
      headers: {'content-type': 'text/html; charset=utf-8'},
    ),
    '/v2/novel/series': reviewJson({
      'novel_series_detail': {
        'id': 77,
        'title': 'series 77',
        'caption': 'series caption',
        'is_original': true,
        'is_concluded': false,
        'content_count': 12,
        'total_character_count': 48000,
        'user': reviewUserJson(99),
        'display_text': 'display text',
        'novel_ai_type': 0,
        'watchlist_added': false,
        'created_at': '2026-01-01T00:00:00+00:00',
        'updated_at': '2026-09-01T00:00:00+00:00',
      },
      'novel_series_first_novel': reviewNovelJson(2000),
      'novel_series_latest_novel': reviewNovelJson(2011),
      'novels': novels(2000, 12),
      'next_url': null,
    }),
    '/v1/spotlight/articles': reviewJson({
      'spotlight_articles': [
        for (var i = 101; i <= 104; i++)
          {
            'id': i,
            'title': 'spotlight $i',
            'pure_title': 'pure $i',
            'thumbnail': 'https://i.pximg.net/spotlight/$i.jpg',
            'article_url': 'https://www.pixivision.net/a/$i',
            'publish_date': '2026-09-0${i - 100}',
            'category': 'illust',
            'subcategory_label': 'label $i',
          },
      ],
      'next_url': null,
    }),
    '/v1/mute/list': reviewJson({
      'muted_tags': [
        {'tag': 'muted-tag'},
      ],
      'muted_users': <Map<String, dynamic>>[],
      'mute_limit_count': 30,
    }),
    '/v1/mute/edit': reviewJson(const {}),
    '/v2/illust/bookmark/add': reviewJson(const {}),
    '/v1/illust/bookmark/delete': reviewJson(const {}),
    // Read before a delete, so only bookmarked works ask: it is what
    // Undo restores.
    '/v2/illust/bookmark/detail': reviewJson({
      'bookmark_detail': {
        'is_bookmarked': true,
        'tags': <Object?>[],
        'restrict': 'public',
      },
    }),
    '/v2/novel/bookmark/add': reviewJson(const {}),
    '/v1/novel/bookmark/delete': reviewJson(const {}),
    '/v2/novel/bookmark/detail': reviewJson({
      'bookmark_detail': {
        'is_bookmarked': true,
        'tags': <Object?>[],
        'restrict': 'public',
      },
    }),
    '/v1/user/follow/add': reviewJson(const {}),
    '/v1/user/follow/delete': reviewJson(const {}),
    '/v1/user/profile/edit': reviewJson(const {}),
    '/v1/illust/comment/add': reviewJson({'comment': reviewCommentJson(99, 1)}),
    '/v1/illust/comment/delete': reviewJson(const {}),
    '/v1/novel/comment/add': reviewJson({'comment': reviewCommentJson(99, 1)}),
    '/v1/novel/comment/delete': reviewJson(const {}),
    '/v1/user/ai-show-settings': reviewJson({'show_ai': true}),
    '/v1/user/ai-show-settings/edit': reviewJson({'show_ai': true}),
    '/v1/user/restricted-mode-settings': reviewJson({
      'is_restricted_mode_enabled': false,
    }),
    '/v1/ugoira/metadata': reviewJson({
      'ugoira_metadata': {
        'frames': [
          {'file': '0.jpg', 'delay': 100},
        ],
        'zip_urls': {'medium': 'https://i.pximg.net/ugoira.zip'},
      },
    }),
    '/v1/watchlist/manga': reviewJson({
      'series': [for (var i = 1; i <= 3; i++) reviewWatchlistJson(i)],
      'next_url': null,
    }),
    '/v1/watchlist/novel': reviewJson({
      'series': [for (var i = 10; i <= 12; i++) reviewWatchlistJson(i)],
      'next_url': null,
    }),
    '/v2/user/browsing-history/illust/add': reviewJson(const {}),
    '/v1/illust/prime': reviewJson(const {}),
  };
}
