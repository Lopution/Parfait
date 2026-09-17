import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:pixiv_func/core/paging/paged_feed_controller.dart';
import 'package:pixiv_func/core/search/search_repository.dart' show TrendingTag;
import 'package:pixiv_func/core/search/search_trending_controller.dart';
import 'package:pixiv_func/core/spotlight/spotlight_feed_controller.dart';
import 'package:pixiv_func/core/spotlight/spotlight_models.dart';
import 'package:pixiv_func/core/spotlight/spotlight_store.dart';
import 'package:pixiv_func/features/search/search_page.dart';
import 'package:pixiv_func/features/spotlight/spotlight_feed_page.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/spotlight_world.dart';
import 'helpers/test_preferences.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test('spotlight feed loads page one and commits the article store', () async {
    final (container, fixture) = await makeSpotlightWorld();
    addTearDown(container.dispose);

    final state = await container.read(
      spotlightFeedProvider(SpotlightCategory.all).future,
    );

    expect(state.ids, [101, 102]);
    expect(state.initialPhase, FeedPhase.idle);
    expect(state.exhausted, isFalse);
    expect(fixture.requests.single.queryParameters['category'], 'all');

    final store = container.read(spotlightArticleStoreProvider);
    expect(store[101]?.title, 'spotlight 101');
    expect(store[102]?.articleUrl, 'https://www.pixivision.net/a/102');
  });

  test('categories have independent feeds and cursors', () async {
    final (container, fixture) = await makeSpotlightWorld();
    addTearDown(container.dispose);

    await container.read(spotlightFeedProvider(SpotlightCategory.all).future);
    await container.read(spotlightFeedProvider(SpotlightCategory.manga).future);
    expect(fixture.requests.map((uri) => uri.queryParameters['category']), [
      'all',
      'manga',
    ]);

    await container
        .read(spotlightFeedProvider(SpotlightCategory.manga).notifier)
        .loadMore();
    final manga = container
        .read(spotlightFeedProvider(SpotlightCategory.manga))
        .requireValue;
    final all = container
        .read(spotlightFeedProvider(SpotlightCategory.all))
        .requireValue;
    expect(manga.ids, [101, 102, 103]);
    expect(manga.exhausted, isTrue);
    expect(all.ids, [101, 102]);
    expect(fixture.requests.last.queryParameters['offset'], '10');
  });

  test('a next_url for another category is rejected before page two', () async {
    final (container, fixture) = await makeSpotlightWorld(
      fixture: SpotlightFixture()..mismatchedNextCategory = 'manga',
    );
    addTearDown(container.dispose);

    final state = await container.read(
      spotlightFeedProvider(SpotlightCategory.all).future,
    );

    expect(state.showInitialError, isTrue);
    expect(state.initialError, isNotNull);
    expect(
      container
          .read(spotlightFeedProvider(SpotlightCategory.all).notifier)
          .nextCursor,
      isNull,
    );
    expect(fixture.requests, hasLength(1));
  });

  testWidgets(
    'spotlight feed page lists articles, switches category, opens article',
    (tester) async {
      final (container, fixture) = await makeSpotlightWorld();
      addTearDown(container.dispose);

      final router = GoRouter(
        initialLocation: '/recommended',
        routes: [
          GoRoute(
            path: '/recommended',
            builder: (_, _) => const SpotlightFeedPage(),
          ),
          GoRoute(
            path: '/recommended/spotlight/article/:articleId',
            builder: (_, state) => Scaffold(
              body: Text(
                'article ${state.pathParameters['articleId']} '
                '${state.uri.queryParameters['url']}',
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Page one committed: two rows with title, label and date.
        expect(find.text('spotlight 101'), findsOneWidget);
        expect(find.text('spotlight 102'), findsOneWidget);
        expect(find.text('label 101'), findsOneWidget);
        expect(find.text('2026-09-01'), findsNWidgets(2));
        expect(fixture.requests.single.queryParameters['category'], 'all');

        // Category selector drives an independent family feed.
        await tester.tap(find.text('插画'));
        await tester.pumpAndSettle();
        expect(fixture.requests.last.queryParameters['category'], 'illust');

        // A row opens the in-app article route with its pixivision URL.
        await tester.tap(find.text('spotlight 101'));
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/recommended/spotlight/article/101');
        expect(
          router.state.uri.queryParameters['url'],
          'https://www.pixivision.net/a/101',
        );
      });
    },
  );

  testWidgets('search guide offers a spotlight entry that opens the feed', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/search',
      routes: [
        GoRoute(path: '/search', builder: (_, _) => const SearchHomePage()),
        GoRoute(
          path: '/search/spotlight',
          builder: (_, _) => const Scaffold(body: Text('spotlight feed')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          trendingTagsProvider.overrideWith((ref) async => <TrendingTag>[]),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('特辑'), findsOneWidget);
    await tester.tap(find.text('特辑'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/search/spotlight');
  });
}
