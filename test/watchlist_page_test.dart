import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/core/novel/reader_settings.dart';
import 'package:parfait/core/watchlist/watchlist_models.dart';
import 'package:parfait/core/watchlist/watchlist_store.dart';
import 'package:parfait/app/widgets/watchlist_toggle.dart';
import 'package:parfait/features/watchlist/watchlist_page.dart';

import 'helpers/fake_account.dart';
import 'helpers/watchlist_world.dart';
import 'helpers/prompt_host.dart';
import 'helpers/localized_app.dart';
import 'helpers/test_preferences.dart';
import 'package:parfait/app/icons/ui_icons.dart';

Widget _app(Widget child) =>
    localizedApp(locale: null, builder: promptHostBuilder, home: child);

void main() {
  testWidgets('watchlist page lists entries under both type tabs; a novel '
      "series' actions open its contents and continue where read", (
    tester,
  ) async {
    final fixture = WatchlistFixture()
      ..mangaSeries = [
        {
          'id': 9,
          'title': 'Series Nine',
          'user': {'id': 5, 'name': 'author-a'},
          'latest_content_id': 777,
          'published_content_count': 3,
          'url': null,
        },
      ]
      ..novelSeries = [
        {
          'id': 21,
          'title': 'Novel Series',
          'user': {'id': 7, 'name': 'author-b'},
          'latest_content_id': 900,
        },
      ];
    final (container, _) = await makeWatchlistWorld(fixture: fixture);
    final router = GoRouter(
      initialLocation: '/recommended',
      routes: [
        GoRoute(path: '/recommended', builder: (_, _) => const WatchlistPage()),
        GoRoute(
          path: '/recommended/novel-series/:seriesId',
          builder: (_, state) =>
              Text('novel series ${state.pathParameters['seriesId']}'),
        ),
        GoRoute(
          path: '/recommended/novel/:novelId',
          builder: (_, state) =>
              Text('novel ${state.pathParameters['novelId']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedRouterApp(
          router,
          locale: null,
          builder: promptHostBuilder,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Series Nine'), findsOneWidget);
    expect(find.textContaining('author-a'), findsWidgets);
    // No read cursor exists yet — the series counts as unseen.
    expect(find.text('New'), findsOneWidget);

    // The novel tab serves the novel watchlist.
    await tester.tap(find.text('Novel'));
    await tester.pumpAndSettle();
    expect(find.text('Novel Series'), findsOneWidget);
    // Its actions open the series' contents; nothing read, no continue.
    await tester.tap(find.byIcon(UiIcons.more));
    await tester.pumpAndSettle();
    expect(find.text('Continue reading'), findsNothing);
    await tester.tap(find.text('Open contents'));
    await tester.pumpAndSettle();
    expect(find.text('novel series 21'), findsOneWidget);

    // A novel of it read before, the actions continue there.
    router.pop();
    await container
        .read(novelSeriesLastReadStoreProvider)
        .write(testerAccount.id, 21, 905);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(UiIcons.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue reading'));
    await tester.pumpAndSettle();
    expect(find.text('novel 905'), findsOneWidget);
  });

  testWidgets('unseen series shows the new-content badge; seen hides it', (
    tester,
  ) async {
    final fixture = WatchlistFixture()
      ..mangaSeries = [
        {
          'id': 9,
          'title': 'Series Nine',
          'user': {'id': 5, 'name': 'author-a'},
          'latest_content_id': 777,
        },
      ];
    final (container, _) = await makeWatchlistWorld(fixture: fixture);
    // A cursor equal to the latest id means "all caught up".
    await container
        .read(watchlistReadCursorProvider)
        .markSeen('100', const WatchlistKey(WatchlistType.manga, 9), 777);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(const WatchlistPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New'), findsNothing);
  });

  testWidgets('toggle reflects the detail flag and posts the mutation', (
    tester,
  ) async {
    final (container, fixture) = await makeWatchlistWorld();
    const key = WatchlistKey(WatchlistType.manga, 9);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(
          const Scaffold(
            body: Center(child: WatchlistToggle(seriesKey: key)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Follow series'), findsOneWidget);

    await tester.tap(find.text('Follow series'));
    await tester.pumpAndSettle();
    expect(find.text('Unfollow series'), findsOneWidget);
    expect(fixture.requests.single.url.path, '/v1/watchlist/manga/add');
    expect(container.read(watchlistStoreProvider)[key]!.added, isTrue);
  });

  testWidgets('toggle reports failure through PromptHost even after unmount', (
    tester,
  ) async {
    final fixture = WatchlistFixture()
      ..mutationStatus = 403
      ..hold = Completer<void>();
    final (container, _) = await makeWatchlistWorld(fixture: fixture);
    const key = WatchlistKey(WatchlistType.manga, 9);
    final showToggle = ValueNotifier<bool>(true);
    addTearDown(showToggle.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(
          Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: showToggle,
              builder: (_, visible, _) => visible
                  ? const Center(child: WatchlistToggle(seriesKey: key))
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Follow series'));
    await tester.pump();
    // Unmount WatchlistToggle while the request is still in flight.
    showToggle.value = false;
    await tester.pump();

    fixture.hold!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Series follow action failed'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a seen cursor that fails to save still opens the work', (
    tester,
  ) async {
    final preferences = IntWriteFailingPreferences();
    final fixture = WatchlistFixture()
      ..mangaSeries = [
        {
          'id': 9,
          'title': 'Series Nine',
          'user': {'id': 5, 'name': 'author-a'},
          'latest_content_id': 777,
        },
      ];
    final (container, _) = await makeWatchlistWorld(
      fixture: fixture,
      preferences: preferences,
    );
    final router = GoRouter(
      initialLocation: '/recommended',
      routes: [
        GoRoute(path: '/recommended', builder: (_, _) => const WatchlistPage()),
        GoRoute(
          path: '/recommended/illust/:illustId',
          builder: (_, state) => Scaffold(
            body: Text('illust ${state.pathParameters['illustId']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedRouterApp(
          router,
          locale: null,
          builder: promptHostBuilder,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Series Nine'));
    await tester.pumpAndSettle();

    expect(find.text('illust 777'), findsOneWidget);
    expect(preferences.intWrites, [777]);
  });

  testWidgets(
    'watchlist load-more retries via FeedTail, removal updates in place with error restore, and novel without latest opens series',
    (tester) async {
      final fixture = WatchlistFixture()
        ..mangaSeries = [
          {
            'id': 9,
            'title': 'Manga Nine',
            'user': {'id': 5, 'name': 'author-a'},
            'latest_content_id': 777,
          },
          {
            'id': 10,
            'title': 'Manga Ten',
            'user': {'id': 6, 'name': 'author-b'},
            'latest_content_id': 778,
          },
          for (var i = 1; i <= 6; i++)
            {
              'id': 100 + i,
              'title': 'Manga Extra $i',
              'user': {'id': 50 + i, 'name': 'author-$i'},
              'latest_content_id': 800 + i,
            },
        ]
        ..mangaNextUrl = 'https://app-api.pixiv.net/v1/watchlist/manga?offset=2'
        ..mangaNextSeries = [
          {
            'id': 11,
            'title': 'Manga Eleven',
            'user': {'id': 7, 'name': 'author-c'},
            'latest_content_id': 779,
          },
        ]
        ..failNextPageOnce = true
        ..mutationStatus = 400
        ..novelSeries = [
          {
            'id': 33,
            'title': 'No Latest Novel',
            'user': {'id': 8, 'name': 'author-d'},
            'latest_content_id': null,
          },
        ];
      final (container, _) = await makeWatchlistWorld(fixture: fixture);
      final router = GoRouter(
        initialLocation: '/recommended',
        routes: [
          GoRoute(
            path: '/recommended',
            builder: (_, _) => const WatchlistPage(),
          ),
          GoRoute(
            path: '/recommended/novel-series/:seriesId',
            builder: (_, state) =>
                Text('novel series ${state.pathParameters['seriesId']}'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: localizedRouterApp(
            router,
            locale: null,
            builder: promptHostBuilder,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Trigger load-more failure, then retry via FeedTail's Retry button.
      final listScrollable = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text('Retry'),
        300,
        scrollable: listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Manga Eleven'),
        300,
        scrollable: listScrollable,
      );
      expect(find.text('Manga Eleven'), findsOneWidget);

      // Scroll back to the top for in-place removal checks on Manga Nine.
      await tester.scrollUntilVisible(
        find.text('Manga Nine'),
        -300,
        scrollable: listScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Manga Nine'), findsOneWidget);

      // Failed removal restores entry and surfaces error without reloading page 1.
      final getCountBefore = fixture.requests
          .where((r) => r.method == 'GET')
          .length;
      await tester.tap(find.byIcon(UiIcons.more).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unfollow series'));
      await tester.pumpAndSettle();
      expect(find.text('Manga Nine'), findsOneWidget);
      expect(find.textContaining('Unfollow series'), findsOneWidget);
      expect(
        fixture.requests.where((r) => r.method == 'GET').length,
        getCountBefore,
      );

      // Confirmed removal drops only that entry in place without re-fetching GET.
      fixture.mutationStatus = 200;
      await tester.tap(find.byIcon(UiIcons.more).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unfollow series'));
      await tester.pumpAndSettle();
      expect(find.text('Manga Nine'), findsNothing);
      expect(find.text('Manga Ten'), findsOneWidget);
      expect(
        fixture.requests.where((r) => r.method == 'GET').length,
        getCountBefore,
      );

      // Novel watchlist entry without latestContentId falls back to novel series.
      await tester.tap(find.text('Novel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No Latest Novel'));
      await tester.pumpAndSettle();
      expect(find.text('novel series 33'), findsOneWidget);
    },
  );
}
