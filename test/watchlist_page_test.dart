import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/actionqueue/action_bootstrap.dart';
import 'package:pixiv_func/core/actionqueue/action_store.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/series/series_recent_open_store.dart';
import 'package:pixiv_func/core/watchlist/watchlist_models.dart';
import 'package:pixiv_func/core/watchlist/watchlist_store.dart';
import 'package:pixiv_func/app/widgets/watchlist_toggle.dart';
import 'package:pixiv_func/features/watchlist/watchlist_page.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

class _Fixture {
  final requests = <http.Request>[];
  List<Map<String, Object?>> mangaSeries = const [];
  List<Map<String, Object?>> novelSeries = const [];

  http.Client build() => MockClient((request) async {
    requests.add(request);
    if (request.method == 'GET') {
      final isNovel = request.url.path.contains('/novel');
      return http.Response(
        jsonEncode({
          'series': isNovel ? novelSeries : mangaSeries,
          'next_url': null,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode({'is_success': true}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

Future<(ProviderContainer, _Fixture)> _makeWorld({_Fixture? fixture}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final resolvedFixture = fixture ?? _Fixture();
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
            fail('refresh should not happen in watchlist page tests');
          }),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client not wired yet');
        return client;
      }),
      actionStoreProvider.overrideWithValue(InMemoryActionStore()),
    ],
  );
  final client = PixivHttpClient(
    client: resolvedFixture.build(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  return (container, resolvedFixture);
}

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
    final fixture = _Fixture()
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
    final (container, _) = await _makeWorld(fixture: fixture);
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

  testWidgets('unseen series shows the new-content badge; seen hides it', (
    tester,
  ) async {
    final fixture = _Fixture()
      ..mangaSeries = [
        {
          'id': 9,
          'title': 'Series Nine',
          'user': {'id': 5, 'name': 'author-a'},
          'latest_content_id': 777,
        },
      ];
    final (container, _) = await _makeWorld(fixture: fixture);
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
    final (container, fixture) = await _makeWorld();
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

  testWidgets('icon toggle renders the compact variant', (tester) async {
    final (container, _) = await _makeWorld();
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
    // The detail payload was observed into the store.
    expect(container.read(watchlistStoreProvider)[key]!.added, isTrue);
  });

  testWidgets('tiles split view-updates, contents, return and unwatch', (
    tester,
  ) async {
    final fixture = _Fixture()
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
    final (container, _) = await _makeWorld(fixture: fixture);
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
