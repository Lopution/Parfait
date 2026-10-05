import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:parfait/app/motion/press_scale.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/widgets/feed/spotlight_article_card.dart';
import 'package:parfait/core/paging/paged_feed_controller.dart';
import 'package:parfait/core/search/search_repository.dart' show TrendingTag;
import 'package:parfait/core/search/search_trending_controller.dart';
import 'package:parfait/core/spotlight/spotlight_feed_controller.dart';
import 'package:parfait/core/spotlight/spotlight_models.dart';
import 'package:parfait/core/spotlight/spotlight_store.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/spotlight/spotlight_feed_page.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
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

        // Page one committed: two cards, each image → title → date, with
        // no trailing arrow.
        expect(find.text('spotlight 101'), findsOneWidget);
        expect(find.text('spotlight 102'), findsOneWidget);
        final card = find.widgetWithText(SpotlightArticleCard, 'spotlight 101');
        expect(
          find.descendant(of: card, matching: find.byType(PressScale)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card, matching: find.byIcon(Icons.chevron_right)),
          findsNothing,
        );
        final image = find.descendant(
          of: card,
          matching: find.byType(PixivImage),
        );
        final title = find.text('spotlight 101');
        final date = find.descendant(
          of: card,
          matching: find.text('2026年9月1日'),
        );
        expect(
          tester.getRect(image).bottom,
          lessThanOrEqualTo(tester.getRect(title).top),
        );
        expect(
          tester.getRect(title).bottom,
          lessThanOrEqualTo(tester.getRect(date).top),
        );
        expect(
          tester.getSize(image).aspectRatio,
          closeTo(SpotlightArticleCard.imageAspectRatio, 0.01),
        );
        expect(find.text('label 101'), findsNothing);
        expect(fixture.requests.single.queryParameters['category'], 'all');

        // Thumbnails are pximg URLs: they must carry the Pixiv referer
        // (PixivImage) and decode for the card's width.
        final thumbnails = tester.widgetList<PixivImage>(
          find.byType(PixivImage),
        );
        expect(thumbnails.map((image) => image.url), [
          'https://i.pximg.net/spotlight/101.jpg',
          'https://i.pximg.net/spotlight/102.jpg',
        ]);
        expect(thumbnails.map((image) => image.memCacheWidth).toSet(), {
          PixivImage.decodeWidthFor(tester.getSize(image).width),
        });

        // Category tabs drive independent family feeds.
        await tester.tap(find.widgetWithText(Tab, '插画'));
        await tester.pumpAndSettle();
        expect(fixture.requests.last.queryParameters['category'], 'illust');
        await tester.tap(find.widgetWithText(Tab, '全部'));
        await tester.pumpAndSettle();

        // A card opens the in-app article route with its pixivision URL.
        // The illust tab keeps its list beside this one; tap the visible card.
        await tester.tap(find.text('spotlight 101').hitTestable());
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/recommended/spotlight/article/101');
        expect(
          router.state.uri.queryParameters['url'],
          'https://www.pixivision.net/a/101',
        );
      });
    },
  );

  testWidgets('the search guide shows the newest five articles', (
    tester,
  ) async {
    final (container, fixture) = await makeSpotlightWorld(
      fixture: SpotlightFixture()..firstPageSize = 7,
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/search',
      routes: [
        GoRoute(path: '/search', builder: (_, _) => const SearchHomePage()),
        GoRoute(
          path: '/search/spotlight',
          builder: (_, _) => const Scaffold(body: Text('spotlight feed')),
        ),
        GoRoute(
          path: '/search/spotlight/article/:articleId',
          builder: (_, state) => Scaffold(
            body: Text('article ${state.pathParameters['articleId']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: ProviderScope(
            overrides: [
              trendingTagsProvider.overrideWith((ref, _) => <TrendingTag>[]),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The list's first page ("all") feeds the strip: five cards, each
      // with its image, title and date.
      expect(fixture.requests.single.queryParameters['category'], 'all');
      expect(find.byType(SpotlightArticleCard), findsNWidgets(5));
      expect(find.text('spotlight 105', skipOffstage: false), findsOneWidget);
      expect(find.text('spotlight 106', skipOffstage: false), findsNothing);
      final first = find.widgetWithText(SpotlightArticleCard, 'spotlight 101');
      expect(
        find.descendant(of: first, matching: find.text('2026年9月1日')),
        findsOneWidget,
      );

      // A card opens its article.
      await tester.tap(find.text('spotlight 101'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/search/spotlight/article/101');
      router.pop();
      await tester.pumpAndSettle();

      // The header row, "See all" included, opens the full list.
      final header = find.ancestor(
        of: find.text('全部'),
        matching: find.byType(InkWell),
      );
      expect(
        tester.getSemantics(header),
        isSemantics(isButton: true, isHeader: true, label: '特辑\n全部'),
      );
      expect(tester.getSize(header).height, greaterThanOrEqualTo(48));
      await tester.tap(find.text('特辑'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/search/spotlight');
    });
  });
}
