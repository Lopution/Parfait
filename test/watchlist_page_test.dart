import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/core/watchlist/watchlist_models.dart';
import 'package:parfait/core/watchlist/watchlist_store.dart';
import 'package:parfait/app/widgets/watchlist_toggle.dart';
import 'package:parfait/features/watchlist/watchlist_page.dart';

import 'helpers/watchlist_world.dart';
import 'helpers/prompt_host.dart';
import 'helpers/localized_app.dart';
import 'helpers/test_preferences.dart';

Widget _app(Widget child) =>
    localizedApp(locale: null, builder: promptHostBuilder, home: child);

void main() {
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
}
