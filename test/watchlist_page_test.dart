import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:parfait/app/haptics/app_haptics.dart';
import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/core/series/series_recent_open_store.dart';
import 'package:parfait/core/watchlist/watchlist_models.dart';
import 'package:parfait/core/watchlist/watchlist_store.dart';
import 'package:parfait/app/motion/state_icon_switcher.dart';
import 'package:parfait/app/widgets/entity_row.dart';
import 'package:parfait/app/widgets/watchlist_toggle.dart';
import 'package:parfait/features/watchlist/watchlist_page.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/watchlist_world.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/test_preferences.dart';

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: appLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('watchlist page lists entries under both type tabs', (
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
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(const WatchlistPage()),
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
  });

  testWidgets('feed caps at the management content width', (tester) async {
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
    addTearDown(container.dispose);

    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(const WatchlistPage()),
      ),
    );
    await tester.pumpAndSettle();

    final rowRect = tester.getRect(find.byType(EntityRow));
    expect(rowRect.width, 840);
    expect(rowRect.left, (1200 - 840) / 2);
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
    addTearDown(container.dispose);
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
    addTearDown(container.dispose);
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

  testWidgets('toggle haptics follow the settled outcome', (tester) async {
    final haptics = recordHaptics();
    final (container, fixture) = await makeWatchlistWorld();
    addTearDown(container.dispose);
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
    expect(haptics.played, isEmpty);

    await tester.tap(find.text('Follow series'));
    await tester.pumpAndSettle();
    expect(haptics.roles, [HapticRole.toggleOn]);

    // The throttle reads the wall clock; let the light lane re-arm.
    await tester.runAsync(() => Future<void>.delayed(AppHaptics.lightInterval));
    await tester.tap(find.text('Unfollow series'));
    await tester.pumpAndSettle();
    expect(haptics.roles, [HapticRole.toggleOn, HapticRole.toggleOff]);

    fixture.mutationStatus = 400;
    await tester.tap(find.text('Follow series'));
    await tester.pumpAndSettle();
    expect(container.read(watchlistStoreProvider)[key]!.added, isFalse);
    expect(haptics.roles, [
      HapticRole.toggleOn,
      HapticRole.toggleOff,
      HapticRole.error,
    ]);
  });

  testWidgets('icon toggle renders the compact variant', (tester) async {
    final (container, _) = await makeWatchlistWorld();
    addTearDown(container.dispose);
    const key = WatchlistKey(WatchlistType.novel, 21);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(
          const Scaffold(
            body: Center(
              child: WatchlistToggle(
                seriesKey: key,
                detailAdded: true,
                iconOnly: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bookmark_added), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byIcon(Icons.bookmark_added),
        matching: find.byType(StateIconSwitcher),
      ),
      findsOneWidget,
    );
    // The detail payload was observed into the store.
    expect(container.read(watchlistStoreProvider)[key]!.added, isTrue);
  });

  testWidgets('tiles split view-updates, contents, return and unwatch', (
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
    addTearDown(container.dispose);
    // Session memory: the user last opened part 4 of series 9.
    container
        .read(seriesRecentOpenStoreProvider.notifier)
        .record(accountId: '100', seriesId: 9, illustId: 555, contentOrder: 4);

    final router = _stubRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _routerApp(router),
      ),
    );
    await tester.pumpAndSettle();

    // Tap = view updates: manga opens the latest work and advances the
    // read cursor (cursor = update marker, not a reading position).
    await tester.tap(find.text('Series Nine'));
    await tester.pumpAndSettle();
    expect(find.text('illust 777'), findsOneWidget);
    expect(
      await container
          .read(watchlistReadCursorProvider)
          .read('100', const WatchlistKey(WatchlistType.manga, 9)),
      777,
    );
    router.pop();
    await tester.pumpAndSettle();

    // Overflow menu: contents (manga only) + return-to-last-opened +
    // unwatch.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Open contents'), findsOneWidget);
    expect(find.text('Back to part 4'), findsOneWidget);
    expect(find.text('Unfollow series'), findsOneWidget);

    await tester.tap(find.text('Back to part 4'));
    await tester.pumpAndSettle();
    expect(find.text('illust 555'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open contents'));
    await tester.pumpAndSettle();
    expect(find.text('series 9'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    // Novel tab: tap opens the latest novel; the menu has no contents
    // entry (D3) and no return item (no recent-open record for novels).
    await tester.tap(find.text('Novel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Novel Series'));
    await tester.pumpAndSettle();
    expect(find.text('novel 900'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Open contents'), findsNothing);
    expect(find.text('Unfollow series'), findsOneWidget);

    await tester.tap(find.text('Unfollow series'));
    await tester.pumpAndSettle();
    expect(
      fixture.requests.map((r) => r.url.path),
      contains('/v1/watchlist/novel/delete'),
    );
  });

  testWidgets('scrolling a tab feed scrolls the app bar under', (tester) async {
    final fixture = WatchlistFixture()
      ..mangaSeries = [
        for (var i = 0; i < 24; i++)
          {
            'id': 100 + i,
            'title': 'Series $i',
            'user': {'id': 5, 'name': 'author'},
            'latest_content_id': 700 + i,
          },
      ];
    final (container, _) = await makeWatchlistWorld(fixture: fixture);
    addTearDown(container.dispose);

    final theme = replicaTheme(Brightness.dark);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: mui.MaterialApp(
          theme: theme,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const WatchlistPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Color appBarColor() => tester
        .widget<mui.Material>(
          find
              .descendant(
                of: find.byType(mui.AppBar),
                matching: find.byType(mui.Material),
              )
              .first,
        )
        .color!;
    expect(appBarColor(), theme.scaffoldBackgroundColor);

    // The feeds sit inside the TabBarView's PageView — their notifications
    // reach the bar at depth 1, which the page's predicate accepts.
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(appBarColor(), theme.colorScheme.surfaceContainer);
  });
}

GoRouter _stubRouter() => GoRouter(
  initialLocation: '/recommended',
  routes: [
    GoRoute(path: '/recommended', builder: (_, _) => const WatchlistPage()),
    GoRoute(
      path: '/recommended/illust/:id',
      builder: (_, state) =>
          Scaffold(body: Text('illust ${state.pathParameters['id']}')),
    ),
    GoRoute(
      path: '/recommended/novel/:id',
      builder: (_, state) =>
          Scaffold(body: Text('novel ${state.pathParameters['id']}')),
    ),
    GoRoute(
      path: '/recommended/series/:id',
      builder: (_, state) =>
          Scaffold(body: Text('series ${state.pathParameters['id']}')),
    ),
  ],
);

Widget _routerApp(GoRouter router) => MaterialApp.router(
  localizationsDelegates: appLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  routerConfig: router,
);
