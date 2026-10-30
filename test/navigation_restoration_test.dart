import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/core/history/history_database.dart';
import 'package:parfait/core/history/history_repository.dart';
import 'package:parfait/core/illust/ranking_repository.dart';
import 'package:parfait/core/illust/recommended_repository.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/search/search_repository.dart';
import 'package:parfait/core/search/search_trending_controller.dart';
import 'package:parfait/features/history/history_page.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_pager_page.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:parfait/features/profile/bookmark_tag_feed_page.dart';
import 'package:parfait/features/ranking/ranking_page.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'helpers/api_responses.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/search_world.dart';

Widget _routerApp(
  GoRouter router, {
  List<TrendingTag>? trendingTags,
  Future<http.Response> Function(http.Request)? httpHandler,
  http.Client? transport,
  HistoryRepository? history,
}) {
  return ProviderScope(
    overrides: [
      if (history != null) historyRepositoryProvider.overrideWithValue(history),
      ...accountProviderOverrides(
        credentialStore: FakeCredentialStore(
          values: const {
            'account': Credential(
              accessToken: 'access-token',
              refreshToken: 'refresh-token',
            ),
          },
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(client: MockClient((_) async => http.Response('{}', 400))),
      ),
      if (trendingTags != null)
        trendingTagsProvider.overrideWith((ref, _) => trendingTags),
      if (httpHandler != null ? MockClient(httpHandler) : transport
          case final client?)
        pixivHttpClientProvider.overrideWith(
          (ref) => PixivHttpClient(
            client: client,
            accountStore: ref.read(accountStoreProvider.notifier),
            credentialStore: ref.read(credentialStoreProvider),
            oauthService: ref.read(oauthServiceProvider),
          ),
        ),
    ],
    child: MaterialApp.router(
      restorationScopeId: 'parfait',
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      routerConfig: router,
    ),
  );
}

http.Response _json(Map<String, dynamic> value) => jsonResponse(value);

void main() {
  setUp(
    () => seedAccounts([
      const Account(id: 'account', userId: 1, name: 'tester'),
    ], currentId: 'account'),
  );

  testWidgets('restores the active search branch and its nested route', (
    tester,
  ) async {
    final router = pixivRouter('/search/input?q=cat&type=illust');

    await tester.pumpWidget(
      _routerApp(
        router,
        transport: PixivApi({...shellRoutes, ...SearchApi().routes}).client,
      ),
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
    final router = pixivRouter('/ranking?mode=week&date=2025-10-01');

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
    await tester.tap(find.byType(Tab).at(9));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/ranking');
    expect(router.state.uri.queryParameters['mode'], 'weekR18');
    expect(router.state.uri.queryParameters['date'], '2025-10-01');
    expect(
      tester.widget<RankingPage>(find.byType(RankingPage)).initialMode,
      RankingMode.weekR18,
    );
    expect(
      tester.widget<RankingPage>(find.byType(RankingPage)).date,
      DateTime(2025, 10, 1),
    );

    await tester.restartAndRestore();
    await tester.pump();

    expect(router.state.uri.path, '/ranking');
    expect(router.state.uri.queryParameters['mode'], 'weekR18');
    expect(router.state.uri.queryParameters['date'], '2025-10-01');
    expect(
      tester.widget<RankingPage>(find.byType(RankingPage)).initialMode,
      RankingMode.weekR18,
    );
    expect(
      tester.widget<RankingPage>(find.byType(RankingPage)).date,
      DateTime(2025, 10, 1),
    );
  });

  testWidgets('replaces and restores the recommended content type', (
    tester,
  ) async {
    final router = pixivRouter('/recommended?type=manga');

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

  testWidgets('restores the bookmark tag feed tag and restrict', (
    tester,
  ) async {
    final router = pixivRouter(
      '/recommended/bookmarks/tag?tag=cat&restrict=private',
    );

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
    final router = pixivRouter('/search');

    await tester.pumpWidget(
      _routerApp(
        router,
        trendingTags: [
          for (var index = 0; index < 30; index++)
            TrendingTag(name: 'tag-${index + 1}'),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const PageStorageKey('search-home-illust')),
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
            of: find.byKey(const PageStorageKey('search-home-illust')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(restoredScrollable.position.pixels, 260);
  });

  testWidgets('viewer page replacement survives route restoration', (
    tester,
  ) async {
    final router = pixivRouter('/recommended');

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
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/recommended/illust/42/viewer/1');
    expect(find.text('2 / 2'), findsOneWidget);

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/recommended/illust/42/viewer/1');
    expect(find.byType(ImageViewerPage), findsOneWidget);
  });

  testWidgets('a restored pager opens the work it settled on', (tester) async {
    // Detail pages track visibility; a zero interval avoids a periodic
    // timer outliving the test.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    addTearDown(
      () => VisibilityDetectorController.instance.updateInterval =
          const Duration(milliseconds: 500),
    );
    // History outlives the restart, as its database outlives the process:
    // the torn-down pager's last view lands in it, not in a closed one.
    final historyDatabase = HistoryDatabase();
    final history = HistoryRepository(database: historyDatabase);
    final router = pixivRouter('/recommended');
    await tester.pumpWidget(
      _routerApp(
        router,
        history: history,
        httpHandler: (request) async {
          if (request.url.path == '/v1/illust/detail') {
            final id = int.parse(request.url.queryParameters['illust_id']!);
            return _json({'illust': illustJson(id)});
          }
          return _json({'illusts': <Object?>[], 'next_url': null});
        },
      ),
    );
    await tester.pump();
    final source = IllustPagerSource()..update(const [42, 43]);
    unawaited(
      router.push(
        '/recommended/illust/42',
        extra: IllustRouteExtra(pagerSource: source),
      ),
    );
    await tester.pumpAndSettle();
    final pager = find
        .descendant(
          of: find.byType(IllustDetailPagerPage),
          matching: find.byType(PageView),
        )
        .first;

    await tester.flingFrom(
      tester.getTopLeft(pager) + const Offset(195, 200),
      const Offset(-260, 0),
      900,
    );
    await tester.pumpAndSettle();
    // Past the dwell: 43 is the work being read, not one swiped through.
    await tester.pump(IllustDetailPagerPage.activeDwell);
    expect(tester.widget<PageView>(pager).controller!.page, 1);

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/recommended/illust/42');
    expect(find.byType(IllustDetailPagerPage), findsNothing);
    expect(
      tester.widget<IllustDetailPage>(find.byType(IllustDetailPage)).illustId,
      43,
    );

    // The page goes first, so its last view lands. The database closes
    // here: opened in this case's fake-async zone, a close awaited in a
    // tear-down never returns.
    await tester.pumpWidget(const SizedBox());
    history.dispose();
    await historyDatabase.close();
  });

  for (final (path, type) in [
    ('/settings/history', HistoryPage),
    ('/settings/motion', MotionSettingsPage),
  ]) {
    testWidgets('restores $path on the settings stack', (tester) async {
      final router = pixivRouter(path);

      await tester.pumpWidget(_routerApp(router));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(router.state.uri.path, path);
      expect(find.byType(type), findsOneWidget);

      await tester.restartAndRestore();
      await tester.pump();

      expect(router.state.uri.path, path);
      expect(find.byType(type), findsOneWidget);
    });
  }
}
