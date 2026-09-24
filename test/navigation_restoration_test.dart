import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/bookmark/bookmark_models.dart';
import 'package:pixiv_func/core/illust/ranking_repository.dart';
import 'package:pixiv_func/core/illust/recommended_repository.dart';
import 'package:pixiv_func/core/new/new_feed_models.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/novel/novel_repository.dart';
import 'package:pixiv_func/core/search/search_models.dart';
import 'package:pixiv_func/core/search/search_repository.dart';
import 'package:pixiv_func/core/search/search_trending_controller.dart';
import 'package:pixiv_func/features/home/recommended/recommended_home_page.dart';
import 'package:pixiv_func/features/illust/viewer/image_viewer_page.dart';
import 'package:pixiv_func/features/new/new_page.dart';
import 'package:pixiv_func/features/profile/bookmark_tag_feed_page.dart';
import 'package:pixiv_func/features/ranking/novel_ranking_page.dart';
import 'package:pixiv_func/features/ranking/ranking_page.dart';
import 'package:pixiv_func/features/search/search_page.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

class _StaticSearchRepository implements SearchRepository {
  const _StaticSearchRepository();

  @override
  Future<SearchIllustPage> searchIllust(
    IllustSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async => const SearchIllustPage(illusts: [], nextUrl: null);

  @override
  Future<SearchNovelPage> searchNovel(
    NovelSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async => const SearchNovelPage(novels: [], nextUrl: null);

  @override
  Future<SearchUserPage> searchUsers(
    UserSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async => const SearchUserPage(users: [], nextUrl: null);

  @override
  bool validateCursor(SearchQuery query, {required String cursor}) => true;

  @override
  Future<List<SearchSuggestion>> autocomplete(
    String keyword, {
    CancelToken? cancelToken,
  }) async => const [];

  @override
  Future<List<TrendingTag>> trendingTags({
    SearchResultType type = SearchResultType.illust,
    CancelToken? cancelToken,
  }) async => [
    for (var index = 0; index < 18; index++)
      TrendingTag(name: 'tag-${index + 1}'),
  ];
}

Widget _routerApp(
  GoRouter router, {
  SearchRepository? searchRepository,
  List<TrendingTag>? trendingTags,
  Future<http.Response> Function(http.Request)? httpHandler,
}) {
  return ProviderScope(
    overrides: [
      ...accountProviderOverrides(
        credentialStore: FakeCredentialStore(
          values: const {
            'account': Credential(
              accessToken: 'access-token',
              refreshToken: 'refresh-token',
            ),
          },
        ),
        metadataRepository: FakeAccountMetadataRepository(
          accounts: const [Account(id: 'account', userId: 1, name: 'tester')],
          currentId: 'account',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(client: MockClient((_) async => http.Response('{}', 400))),
      ),
      if (searchRepository != null)
        searchRepositoryProvider.overrideWithValue(searchRepository),
      if (trendingTags != null)
        trendingTagsProvider.overrideWithValue(
          AsyncData<List<TrendingTag>>(trendingTags),
        ),
      if (httpHandler != null)
        pixivHttpClientProvider.overrideWith(
          (ref) => PixivHttpClient(
            client: MockClient(httpHandler),
            accountStore: ref.read(accountStoreProvider.notifier),
            credentialStore: ref.read(credentialStoreProvider),
            oauthService: ref.read(oauthServiceProvider),
          ),
        ),
    ],
    child: MaterialApp.router(
      restorationScopeId: 'pixiv-func',
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      routerConfig: router,
    ),
  );
}

http.Response _json(Map<String, dynamic> value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('restores the active search branch and its nested route', (
    tester,
  ) async {
    final router = createPixivRouter(
      initialLocation: '/search/input?q=cat&type=illust',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _routerApp(router, searchRepository: const _StaticSearchRepository()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(router.state.uri.path, '/search/input');
    expect(router.state.uri.queryParameters, {'q': 'cat', 'type': 'illust'});
    expect(find.byType(SearchInputPage), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'cat',
    );

    await tester.tap(find.text('小说'));
    await tester.pumpAndSettle();

    expect(router.state.uri.queryParameters, {'q': 'cat', 'type': 'novel'});
    expect(
      tester.widget<SearchInputPage>(find.byType(SearchInputPage)).initialType,
      SearchResultType.novel,
    );

    await tester.restartAndRestore();
    await tester.pump();

    expect(router.state.uri.path, '/search/input');
    expect(router.state.uri.queryParameters, {'q': 'cat', 'type': 'novel'});
    expect(find.byType(SearchInputPage), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'cat',
    );
  });

  testWidgets('replaces and restores the selected ranking mode', (
    tester,
  ) async {
    final router = createPixivRouter(initialLocation: '/ranking?mode=week');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _routerApp(
        router,
        httpHandler: (_) async =>
            _json({'illusts': <Object?>[], 'next_url': null}),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tester.widget<RankingPage>(find.byType(RankingPage)).initialMode,
      RankingMode.week,
    );
    await tester.tap(find.byType(Tab).at(7));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/ranking');
    expect(router.state.uri.queryParameters['mode'], 'weekR18');
    expect(
      tester.widget<RankingPage>(find.byType(RankingPage)).initialMode,
      RankingMode.weekR18,
    );

    await tester.restartAndRestore();
    await tester.pump();

    expect(router.state.uri.path, '/ranking');
    expect(router.state.uri.queryParameters['mode'], 'weekR18');
    expect(
      tester.widget<RankingPage>(find.byType(RankingPage)).initialMode,
      RankingMode.weekR18,
    );
  });

  testWidgets('replaces and restores the selected novel ranking mode', (
    tester,
  ) async {
    final router = createPixivRouter(
      initialLocation: '/ranking/novel-ranking?mode=week',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _routerApp(
        router,
        httpHandler: (_) async =>
            _json({'novels': <Object?>[], 'next_url': null}),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tester
          .widget<NovelRankingPage>(find.byType(NovelRankingPage))
          .initialMode,
      NovelRankingMode.week,
    );

    // Same gesture family as the illust ranking: a tab tap writes the mode
    // back through context.replace.
    await tester.tap(find.byType(Tab).at(0));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/ranking/novel-ranking');
    expect(router.state.uri.queryParameters['mode'], 'day');
    expect(
      tester
          .widget<NovelRankingPage>(find.byType(NovelRankingPage))
          .initialMode,
      NovelRankingMode.day,
    );

    await tester.restartAndRestore();
    await tester.pump();

    expect(router.state.uri.path, '/ranking/novel-ranking');
    expect(router.state.uri.queryParameters['mode'], 'day');
    expect(
      tester
          .widget<NovelRankingPage>(find.byType(NovelRankingPage))
          .initialMode,
      NovelRankingMode.day,
    );
  });

  testWidgets('replaces and restores the recommended content type', (
    tester,
  ) async {
    final router = createPixivRouter(
      initialLocation: '/recommended?type=manga',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _routerApp(
        router,
        httpHandler: (_) async =>
            _json({'illusts': <Object?>[], 'next_url': null}),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tester
          .widget<RecommendedHomePage>(find.byType(RecommendedHomePage))
          .initialType,
      RecommendedContentType.manga,
    );

    // A type tap writes the durable value back through context.replace.
    await tester.tap(find.text('插画'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/recommended');
    expect(router.state.uri.queryParameters['type'], 'illust');
    expect(
      tester
          .widget<RecommendedHomePage>(find.byType(RecommendedHomePage))
          .initialType,
      RecommendedContentType.illust,
    );

    await tester.restartAndRestore();
    await tester.pump();

    expect(router.state.uri.path, '/recommended');
    expect(router.state.uri.queryParameters['type'], 'illust');
    expect(
      tester
          .widget<RecommendedHomePage>(find.byType(RecommendedHomePage))
          .initialType,
      RecommendedContentType.illust,
    );
  });

  testWidgets('replaces and restores the new feed scope and type', (
    tester,
  ) async {
    final router = createPixivRouter(
      initialLocation: '/new?scope=everyone&type=novel',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _routerApp(
        router,
        httpHandler: (_) async =>
            _json({'novels': <Object?>[], 'next_url': null}),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    var page = tester.widget<NewPage>(find.byType(NewPage));
    expect(page.initialScope, NewFeedScope.everyone);
    expect(page.initialType, NewFeedType.novel);

    // A scope tap writes scope+type back through context.replace — the
    // pair stays one durable unit.
    await tester.tap(find.text('关注'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/new');
    expect(router.state.uri.queryParameters['scope'], 'following');
    expect(router.state.uri.queryParameters['type'], 'novel');
    page = tester.widget<NewPage>(find.byType(NewPage));
    expect(page.initialScope, NewFeedScope.following);
    expect(page.initialType, NewFeedType.novel);

    await tester.restartAndRestore();
    await tester.pump();

    expect(router.state.uri.path, '/new');
    expect(router.state.uri.queryParameters['scope'], 'following');
    expect(router.state.uri.queryParameters['type'], 'novel');
    page = tester.widget<NewPage>(find.byType(NewPage));
    expect(page.initialScope, NewFeedScope.following);
    expect(page.initialType, NewFeedType.novel);
  });

  testWidgets('restores the bookmark tag feed tag and restrict', (
    tester,
  ) async {
    final router = createPixivRouter(
      initialLocation: '/recommended/bookmarks/tag?tag=cat&restrict=private',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _routerApp(
        router,
        httpHandler: (_) async =>
            _json({'illusts': <Object?>[], 'next_url': null}),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    var page = tester.widget<BookmarkTagFeedPage>(
      find.byType(BookmarkTagFeedPage),
    );
    expect(page.tag, 'cat');
    expect(page.restrict, BookmarkRestrict.private);
    expect(router.state.uri.queryParameters['tag'], 'cat');
    expect(router.state.uri.queryParameters['restrict'], 'private');

    // Drain the branch landing-ink timer before tearing the tree down.
    await tester.pumpAndSettle();
    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    page = tester.widget<BookmarkTagFeedPage>(find.byType(BookmarkTagFeedPage));
    expect(page.tag, 'cat');
    expect(page.restrict, BookmarkRestrict.private);
  });

  testWidgets('restores a representative feed offset', (tester) async {
    final router = createPixivRouter(initialLocation: '/search');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _routerApp(
        router,
        trendingTags: [
          for (var index = 0; index < 18; index++)
            TrendingTag(name: 'tag-${index + 1}'),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const PageStorageKey('search-home')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    scrollable.position.jumpTo(260);
    await tester.pump();
    expect(scrollable.position.pixels, 260);

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    final restoredScrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const PageStorageKey('search-home')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(restoredScrollable.position.pixels, 260);
  });

  testWidgets('viewer page replacement survives route restoration', (
    tester,
  ) async {
    final router = createPixivRouter(initialLocation: '/recommended');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _routerApp(
        router,
        httpHandler: (request) async {
          if (request.url.path == '/v1/illust/detail') {
            return _json({
              'illust': illustJson(42, pageCount: 2, withMetaPages: true),
            });
          }
          if (request.url.path == '/v2/illust/related') {
            return _json({'illusts': <Object?>[], 'next_url': null});
          }
          return _json({'illusts': <Object?>[], 'next_url': null});
        },
      ),
    );
    await tester.pump();
    unawaited(
      router.push(
        '/recommended/illust/42/viewer/0?quality=original',
        extra: ImageViewerRouteExtra(
          urls: [
            'https://i.pximg.net/42/p0/original.jpg',
            'https://i.pximg.net/42/p1/original.jpg',
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerPage), findsOneWidget);
    expect(find.text('1 / 2'), findsNWidgets(2));

    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/recommended/illust/42/viewer/1');
    expect(find.text('2 / 2'), findsNWidgets(2));

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/recommended/illust/42/viewer/1');
    expect(find.byType(ImageViewerPage), findsOneWidget);
  });
}
