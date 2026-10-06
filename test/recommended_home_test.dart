import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:parfait/app/widgets/follow_switch_button.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/mute/mute_models.dart';
import 'package:parfait/core/mute/mute_store.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/user/follow_store.dart';
import 'package:parfait/core/user/user_repository.dart';
import 'package:parfait/core/user/user_store.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/skeleton/illust_grid_skeleton.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/illust/recommended_feed_controller.dart';
import 'package:parfait/core/illust/recommended_repository.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/fake_account.dart';
import 'helpers/memory_feed_snapshot_store.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';

String _novelJson(int id) => jsonEncode({
  'id': id,
  'title': 'novel $id',
  'caption': '',
  'user': {
    'id': 99,
    'name': 'author',
    'account': 'author',
    'profile_image_urls': {'medium': 'https://i.pximg.net/u.png'},
  },
  'tags': <Object?>[],
  'text_length': 100,
  'create_date': '2026-08-01T10:00:00+09:00',
  'image_urls': {'medium': 'https://i.pximg.net/n$id.png'},
});

/// Preview works per recommended user: user 1 has four (one R-18), user 2
/// none, user 3 one.
final _userPreviewIllusts = <int, List<Map<String, dynamic>>>{
  1: [
    illustJson(101),
    illustJson(102, xRestrict: 1),
    illustJson(103),
    illustJson(104),
  ],
  3: [illustJson(301)],
};

class _ApiFixture {
  _ApiFixture({this.illustCount = 5});

  /// First-page size — a scrollable feed needs enough entries to
  /// overflow the test viewport.
  final int illustCount;

  /// Once set, `/v1/illust/recommended` answers 500 — drives the
  /// refresh-error path after the first page has already loaded.
  bool failRecommended = false;

  /// When set, `/v1/illust/recommended` awaits it — holds the illust
  /// feed's initial load in flight.
  Completer<void>? pendingRecommended;

  /// Once set, every user preview carries a malformed `illusts` field.
  bool malformedPreviews = false;

  final requests = <String>[];

  http.Client build() {
    return MockClient((request) async {
      if (request.url.host != 'app-api.pixiv.net') {
        return http.Response('unknown host', 500);
      }
      final path = request.url.path;
      requests.add('$path?${request.url.query}');
      if (path == '/v1/illust/recommended') {
        await pendingRecommended?.future;
        if (failRecommended) {
          return http.Response('refresh failed', 500);
        }
        return http.Response(
          jsonEncode({
            'illusts': [for (var i = 1; i <= illustCount; i++) illustJson(i)],
            'next_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/v1/novel/recommended') {
        return http.Response(
          jsonEncode({
            'novels': [
              for (var i = 1; i <= 3; i++)
                jsonDecode(_novelJson(i)) as Map<String, dynamic>,
            ],
            'next_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/v1/user/recommended' || path == '/v1/user/following') {
        return http.Response(
          jsonEncode({
            'user_previews': [
              for (var i = 1; i <= 3; i++)
                {
                  'user': {
                    'id': i,
                    'name': 'user $i',
                    'account': 'user$i',
                    'profile_image_urls': {
                      'medium': 'https://i.pximg.net/u$i.png',
                    },
                    'is_followed': i == 3,
                  },
                  'illusts': malformedPreviews
                      ? 'not a list'
                      : [...?_userPreviewIllusts[i]],
                  'novels': <Object?>[],
                },
            ],
            'next_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    });
  }
}

Future<(ProviderContainer, _ApiFixture)> _makeWorld({
  int illustCount = 5,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final fixture = _ApiFixture(illustCount: illustCount);
  final credentials = FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      feedSnapshotStoreProvider.overrideWithValue(MemoryFeedSnapshotStore()),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 'tester')],
          currentId: '100',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async {
            fail('refresh should not happen');
          }),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client not wired yet');
        return client;
      }),
    ],
  );
  final client = PixivHttpClient(
    client: fixture.build(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  return (container, fixture);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('home shows four type chips and defaults to illust', (
    tester,
  ) async {
    final (container, _) = await _makeWorld();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: RecommendedHomePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
    });
    // Locale-independent: four tabs regardless of language.
    expect(find.byType(Tab), findsNWidgets(4));
    // Unified chrome: the TabBar lives inside an AppBar (same as
    // Ranking/New/Search) — a bare TabBar pinned under the status bar was
    // the old divergent style.
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.byType(TabBar)),
      findsOneWidget,
    );
    // Illust cards render (titles from the store).
    expect(find.textContaining('illust '), findsWidgets);
  });

  testWidgets('illust first load shows the grid skeleton', (tester) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);
    fixture.pendingRecommended = Completer<void>();
    addTearDown(() {
      if (fixture.pendingRecommended?.isCompleted == false) {
        fixture.pendingRecommended!.complete();
      }
    });
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: RecommendedHomePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(IllustGridSkeleton), findsOneWidget);
      expect(find.byType(FeedEmpty), findsNothing);

      fixture.pendingRecommended!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(IllustGridSkeleton), findsNothing);
      expect(find.byType(IllustCard), findsWidgets);
    });
  });

  testWidgets('switching to manga requests content_type=manga', (tester) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: RecommendedHomePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byType(Tab).at(1));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
    });
    expect(
      fixture.requests,
      contains(
        '/v1/illust/recommended?content_type=manga&include_ranking_illusts=true&filter=for_ios',
      ),
    );
  });

  testWidgets('type is route-driven and a replace keeps the gesture state', (
    tester,
  ) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);
    final router = createPixivRouter(
      initialLocation: '/recommended?type=manga',
    );
    addTearDown(router.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      // The URL seeds the selected type.
      expect(
        tester
            .widget<RecommendedHomePage>(find.byType(RecommendedHomePage))
            .initialType,
        RecommendedContentType.manga,
      );

      // A tab tap writes back through context.replace — the route rebuild
      // delivers the new initialType while the strip keeps its position.
      await tester.tap(
        find.descendant(
          of: find.byType(RecommendedHomePage),
          matching: find.byType(Tab).at(2),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(router.state.uri.path, '/recommended');
      expect(router.state.uri.queryParameters['type'], 'novel');
      expect(
        tester
            .widget<RecommendedHomePage>(find.byType(RecommendedHomePage))
            .initialType,
        RecommendedContentType.novel,
      );
      expect(
        tester
            .widget<TabBar>(
              find.descendant(
                of: find.byType(RecommendedHomePage),
                matching: find.byType(TabBar),
              ),
            )
            .controller!
            .index,
        2,
      );
    });
    expect(
      fixture.requests,
      contains(
        '/v1/novel/recommended?filter=for_android&include_privacy_policy=true&include_ranking_novels=true',
      ),
    );
  });

  testWidgets('novel chip loads novel recommended and renders titles', (
    tester,
  ) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: RecommendedHomePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byType(Tab).at(2));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
    });
    expect(
      fixture.requests,
      contains(
        '/v1/novel/recommended?filter=for_android&include_privacy_policy=true&include_ranking_novels=true',
      ),
    );
    expect(find.textContaining('novel '), findsWidgets);
  });

  testWidgets('user chip loads user recommended and renders accounts', (
    tester,
  ) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: RecommendedHomePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byType(Tab).at(3));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
    });
    expect(fixture.requests, contains('/v1/user/recommended?filter=for_ios'));
    expect(find.text('user 1'), findsOneWidget);
    expect(find.text('@user1'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  group('recommended users', () {
    Finder thumbnail(int id) => find.byWidgetPredicate(
      (widget) =>
          widget is Semantics && widget.properties.label == 'illust $id',
    );

    Future<GoRouter> pumpUsers(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      final router = createPixivRouter(
        initialLocation: '/recommended?type=user',
      );
      addTearDown(router.dispose);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      return router;
    }

    test('the feed keeps up to three preview works per user', () async {
      final (container, _) = await _makeWorld();
      addTearDown(container.dispose);

      await container.read(
        recommendedFeedProvider((type: RecommendedContentType.user)).future,
      );

      expect(container.read(userPreviewIdsProvider), {
        1: [101, 102, 103],
        2: <int>[],
        3: [301],
      });
      expect(container.read(illustStoreProvider).get(103)?.title, 'illust 103');
      expect(container.read(illustStoreProvider).get(104), isNull);
    });

    test('plain user lists ignore malformed previews', () async {
      final (container, fixture) = await _makeWorld();
      addTearDown(container.dispose);
      fixture.malformedPreviews = true;
      final repository = container.read(userRepositoryProvider);

      final following = await repository.fetchRelation(
        100,
        relation: UserRelation.following,
      );
      expect(following.users.map((user) => user.id), [1, 2, 3]);
      expect(following.previewIllusts, isEmpty);
      // Recommended users do read previews, so the same payload is a
      // parse error there.
      await expectLater(
        repository.fetchRecommended(),
        throwsA(isA<ApiParseError>()),
      );
    });

    testWidgets('shows previews, skipping blocked and muted works', (
      tester,
    ) async {
      final (container, _) = await _makeWorld();
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      await container.read(settingsProvider.notifier).setLocalBlockR18(true);
      container.read(muteStoreProvider);
      await container
          .read(muteStoreProvider.notifier)
          .muteWork(const MutedWork(illustId: 103));

      await mockNetworkImagesFor(() async {
        await pumpUsers(tester, container);
      });

      expect(thumbnail(101), findsOneWidget);
      expect(thumbnail(102), findsNothing); // R-18 with the local block on
      expect(thumbnail(103), findsNothing); // muted
      expect(thumbnail(301), findsOneWidget);
      expect(
        tester.getSemantics(thumbnail(101)),
        isSemantics(isButton: true, hasTapAction: true, label: 'illust 101'),
      );
      // A lone preview keeps its third of the row.
      final row = tester.getRect(
        find.ancestor(of: find.text('user 3'), matching: find.byType(Card)),
      );
      expect(tester.getRect(thumbnail(301)).width, lessThan(row.width / 3));
    });

    testWidgets('follow state comes from the follow store', (tester) async {
      final (container, _) = await _makeWorld();
      addTearDown(container.dispose);

      await mockNetworkImagesFor(() async {
        await pumpUsers(tester, container);
      });

      Finder followButtonOf(String name) => find.descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
        matching: find.byType(FollowSwitchButton),
      );
      expect(
        find.descendant(
          of: followButtonOf('user 3'),
          matching: find.text('已关注'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: followButtonOf('user 1'),
          matching: find.text('关注'),
        ),
        findsOneWidget,
      );
      expect(
        container.read(followStoreProvider.notifier).entryOf(3)?.followed,
        isTrue,
      );
    });

    testWidgets('the user area opens the user, a thumbnail the work', (
      tester,
    ) async {
      final (container, _) = await _makeWorld();
      addTearDown(container.dispose);

      await mockNetworkImagesFor(() async {
        final router = await pumpUsers(tester, container);

        await tester.tap(thumbnail(101));
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/recommended/illust/101');

        router.pop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('user 1'));
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/recommended/user/1');
      });
    });
  });

  testWidgets('branch re-tap scrolls the active feed to top without refetch', (
    tester,
  ) async {
    final (container, fixture) = await _makeWorld(illustCount: 24);
    addTearDown(container.dispose);
    final router = createPixivRouter(initialLocation: '/recommended');
    addTearDown(router.dispose);
    // Compact viewport: at ≥600px the shell swaps the bottom bar for a
    // rail and FuncShellBottomNav leaves the tree.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      final feedView = find.descendant(
        of: find.byType(RecommendedHomePage),
        matching: find.byType(CustomScrollView),
      );
      expect(feedView, findsOneWidget);
      final controller = tester.widget<CustomScrollView>(feedView).controller!;
      controller.jumpTo(400);
      await tester.pump();
      expect(controller.offset, 400);

      // Same-destination tap on the home slot: pure scroll-to-top — no
      // refresh, no re-request.
      final requestsBefore = fixture.requests.length;
      await tester.tap(
        find.descendant(
          of: find.byType(FuncShellBottomNav),
          matching: find.byIcon(AppIcons.home),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(controller.offset, 0);
      expect(fixture.requests.length, requestsBefore);
    });
  });

  testWidgets('a failed refresh surfaces a snackbar, not only a tail row', (
    tester,
  ) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: RecommendedHomePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(shownPrompt, findsNothing);

      // Fail the next recommended request, then refresh — the error must
      // surface in the viewport as a SnackBar with a retry action.
      fixture.failRecommended = true;
      await container
          .read(
            recommendedFeedProvider((
              type: RecommendedContentType.illust,
            )).notifier,
          )
          .refresh();
      await tester.pump();
      await tester.pump();

      expect(shownPrompt, findsOneWidget);
      expect(find.textContaining('刷新失败'), findsOneWidget);
      expect(
        find.descendant(of: shownPrompt, matching: find.text('重试')),
        findsOneWidget,
      );
    });
  });

  testWidgets('sideways drags and tab hops leave the loaded feed unbuilt', (
    tester,
  ) async {
    // Every drag start warms the neighbours and every tab hop rebuilds the
    // page. Neither may reach a feed that is already on screen: on device
    // that rebuilt all of its cards inside the swipe frame.
    final (container, _) = await _makeWorld();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: RecommendedHomePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      // The illust feed's cards as mounted now; any later build of these
      // same elements is a rebuild (the hook's builtOnce flag is only kept
      // under debugPrintRebuildDirtyWidgets).
      final settledCards = find.byType(IllustCard).evaluate().toSet();
      expect(settledCards, isNotEmpty);

      var cardRebuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (settledCards.contains(element)) cardRebuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      // Short, slow drags: the strip follows and reels back, no commit.
      for (var i = 0; i < 2; i++) {
        await tester.timedDrag(
          find.byType(CustomScrollView).first,
          const Offset(-60, 0),
          const Duration(milliseconds: 600),
        );
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byType(Tab).at(1));
      await tester.pumpAndSettle();

      expect(cardRebuilds, 0);
    });
  });
}
