import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/app/icons/app_icons.dart';
import 'package:pixiv_func/app/motion/motion_tokens.dart';
import 'package:pixiv_func/app/widgets/root_swipe_switcher.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/app/widgets/feed/illust_card.dart';
import 'package:pixiv_func/app/widgets/func_bottom_nav.dart';
import 'package:pixiv_func/features/ranking/ranking_page.dart';
import 'package:pixiv_func/core/illust/ranking_repository.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:pixiv_func/core/illust/ranking_feed_controller.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

Map<String, dynamic> _illust(int id) => {
  'id': id,
  'title': 'ranking $id',
  'type': 'illust',
  'image_urls': {
    'square_medium': 'https://i.pximg.net/$id/s.png',
    'medium': 'https://i.pximg.net/$id/m.png',
    'large': 'https://i.pximg.net/$id/l.png',
  },
  'user': {
    'id': 99,
    'name': 'author',
    'account': 'author',
    'profile_image_urls': {'medium': 'https://i.pximg.net/u.png'},
  },
  'tags': <Object>[],
  'page_count': 1,
  'width': 100,
  'height': 140,
  'x_restrict': 0,
  'illust_ai_type': 0,
  'is_bookmarked': false,
  'visible': true,
};

class _RankingFixture {
  _RankingFixture({this.itemsPerPage = 2});

  /// First page size — a scrollable feed needs enough entries to
  /// overflow the test viewport.
  final int itemsPerPage;
  final requests = <Uri>[];
  final Completer<void> release = Completer<void>();
  RankingMode? mismatchedNextMode;
  bool blockResponses = false;

  http.Client client() => MockClient((request) async {
    // Feed builds hydrate MuteStore; the mute list is housekeeping, not a
    // ranking request, so it stays out of `requests`.
    if (request.url.path.endsWith('/v1/mute/list')) {
      return http.Response(
        jsonEncode({
          'muted_tags': <dynamic>[],
          'muted_users': <dynamic>[],
          'mute_limit_count': 500,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    requests.add(request.url);
    if (blockResponses) await release.future;
    final mode = request.url.queryParameters['mode']!;
    final isFirst = request.url.queryParameters['offset'] == null;
    final accountOffset = request.headers['authorization'] == 'Bearer access-2'
        ? 100
        : 0;
    final start = accountOffset + (isFirst ? 1 : 3);
    final nextMode = mismatchedNextMode?.apiValue ?? mode;
    return http.Response(
      jsonEncode({
        'illusts': [
          for (var id = start; id < start + itemsPerPage; id++) _illust(id),
        ],
        'next_url': isFirst
            ? 'https://app-api.pixiv.net/v1/illust/ranking'
                  '?filter=for_android&mode=$nextMode&offset=30'
            : null,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

Future<(ProviderContainer, _RankingFixture)> _makeWorld({
  _RankingFixture? fixture,
  bool twoAccounts = false,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final activeFixture = fixture ?? _RankingFixture();
  final credentials = FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    )
    ..seed(
      '200',
      const Credential(accessToken: 'access-2', refreshToken: 'refresh-2'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: [
            const Account(id: '100', userId: 100, name: 'tester'),
            if (twoAccounts)
              const Account(id: '200', userId: 200, name: 'second'),
          ],
          currentId: '100',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async {
            fail('refresh should not happen in ranking fixture');
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
    client: activeFixture.client(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  return (container, activeFixture);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test('RankingMode has explicit beta56 order and API values', () {
    expect(RankingMode.values.map((mode) => mode.apiValue), [
      'day',
      'day_r18',
      'day_male',
      'day_male_r18',
      'day_female',
      'day_female_r18',
      'week',
      'week_r18',
      'week_original',
      'week_rookie',
      'month',
    ]);
    expect(RankingMode.fromApiValue('week_rookie'), RankingMode.weekRookie);
    expect(RankingMode.fromApiValue('unknown'), isNull);
  });

  test('each mode has independent first page and load-more state', () async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);

    final day = await container.read(
      rankingFeedControllerProvider(RankingMode.day).future,
    );
    final week = await container.read(
      rankingFeedControllerProvider(RankingMode.week).future,
    );
    expect(day.ids, [1, 2]);
    expect(week.ids, [1, 2]);
    expect(fixture.requests.map((uri) => uri.queryParameters['mode']), [
      'day',
      'week',
    ]);

    await container
        .read(rankingFeedControllerProvider(RankingMode.day).notifier)
        .loadMore();
    final dayAfter = container
        .read(rankingFeedControllerProvider(RankingMode.day))
        .requireValue;
    final weekAfter = container
        .read(rankingFeedControllerProvider(RankingMode.week))
        .requireValue;
    expect(dayAfter.ids, [1, 2, 3, 4]);
    expect(weekAfter.ids, [1, 2]);
    expect(weekAfter.exhausted, isFalse);
  });

  test('mismatched next mode is an observable parse error', () async {
    final (container, _) = await _makeWorld(
      fixture: (_RankingFixture()..mismatchedNextMode = RankingMode.week),
    );
    addTearDown(container.dispose);

    final state = await container.read(
      rankingFeedControllerProvider(RankingMode.day).future,
    );
    expect(state.showInitialError, isTrue);
    expect(state.initialError, isNotNull);
    expect(
      container
          .read(rankingFeedControllerProvider(RankingMode.day).notifier)
          .nextCursor,
      isNull,
    );
  });

  test(
    'account switching resets the mode controller and entity store',
    () async {
      final (container, fixture) = await _makeWorld(twoAccounts: true);
      addTearDown(container.dispose);

      final provider = rankingFeedControllerProvider(RankingMode.day);
      final firstStore = container.read(illustStoreProvider);
      expect((await container.read(provider.future)).ids, [1, 2]);

      await container.read(accountStoreProvider.notifier).switchAccount('200');
      final second = await container.read(provider.future);
      final secondStore = container.read(illustStoreProvider);

      expect(second.ids, [101, 102]);
      expect(secondStore, isNot(same(firstStore)));
      expect(fixture.requests, hasLength(2));
      expect(fixture.requests.last, isNotNull);
    },
  );

  test('cancel returns an active feed to idle without an error', () async {
    final fixture = _RankingFixture()..blockResponses = true;
    final (container, _) = await _makeWorld(fixture: fixture);
    addTearDown(container.dispose);

    final future = container.read(
      rankingFeedControllerProvider(RankingMode.day).future,
    );
    await Future<void>.delayed(Duration.zero);
    container
        .read(rankingFeedControllerProvider(RankingMode.day).notifier)
        .cancel();
    final state = await future;
    expect(state.initialPhase.name, 'idle');
    expect(state.initialError, isNull);
  });

  testWidgets('renders all tabs and lazily requests the selected mode', (
    tester,
  ) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),

            home: const RankingPage(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('每日'), findsOneWidget);
      expect(find.text('每月'), findsOneWidget);
      expect(fixture.requests, hasLength(1));

      await tester.tap(find.text('每日(R-18)'));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
    });
    expect(fixture.requests, hasLength(2));
    expect(fixture.requests.last.queryParameters['mode'], 'day_r18');
  });

  testWidgets('rank badges land on the ranked entries', (tester) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),

            home: const RankingPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The first day-mode page carries works 1 and 2; each card pins its
      // rank pill to the top-left badge cluster (O5).
      final cards = find.byType(IllustCard);
      expect(cards, findsNWidgets(2));
      expect(
        find.descendant(of: cards.at(0), matching: find.text('1')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: cards.at(1), matching: find.text('2')),
        findsOneWidget,
      );
      expect(fixture.requests, isNotEmpty);
    });
  });

  // C6 — the sibling-category contract: a TabBar tap and a horizontal
  // strip drag are two injections of the same switch; both must land on
  // the same mode with the same route write, under both motion gates.
  for (final reduce in [false, true]) {
    testWidgets('category tap and drag land identically (reduce: $reduce)', (
      tester,
    ) async {
      final (container, fixture) = await _makeWorld(
        fixture: _RankingFixture(itemsPerPage: 4),
      );
      addTearDown(container.dispose);
      final router = createPixivRouter(initialLocation: '/ranking');
      addTearDown(router.dispose);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),
              routerConfig: router,
              builder: (context, child) =>
                  MotionScope(reduce: reduce, child: child!),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pumpAndSettle();

        // Neighbour warm-up can interleave requests, so assert on the
        // request the landing produced (not merely the last one).
        int requestsFor(String apiMode) => fixture.requests
            .where((u) => u.queryParameters['mode'] == apiMode)
            .length;

        // Tap path: day → dayR18. The strip animates (or snaps under
        // reduce) — either way the same mode lands and the durable
        // route value is written.
        final dayR18Before = requestsFor('day_r18');
        await tester.tap(find.byType(Tab).at(1));
        await tester.pumpAndSettle();
        expect(router.state.uri.queryParameters['mode'], 'dayR18');
        expect(requestsFor('day_r18'), greaterThan(dayR18Before));

        // Drag path back: a committed rightward fling lands on the same
        // slot a tap would — same mode, same route write. The day feed
        // stays mounted across the switch (lazy first load only), so the
        // landing is asserted on index + uri, not a refetch.
        final strip = find.byType(TabSlideStack);
        await tester.fling(strip, const Offset(300, 0), 1200);
        await tester.pumpAndSettle();
        expect(tester.widget<TabSlideStack>(strip).controller.index, 0);
        expect(router.state.uri.queryParameters['mode'], 'day');

        // And forward again by drag — identical landing to the tap.
        await tester.fling(strip, const Offset(-300, 0), 1200);
        await tester.pumpAndSettle();
        expect(tester.widget<TabSlideStack>(strip).controller.index, 1);
        expect(router.state.uri.queryParameters['mode'], 'dayR18');
      });
    });
  }

  testWidgets('branch re-tap scrolls the active ranking feed to top', (
    tester,
  ) async {
    final (container, fixture) = await _makeWorld(
      fixture: _RankingFixture(itemsPerPage: 24),
    );
    addTearDown(container.dispose);
    final router = createPixivRouter(initialLocation: '/ranking');
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
        of: find.byType(RankingPage),
        matching: find.byType(CustomScrollView),
      );
      expect(feedView, findsOneWidget);
      final controller = tester.widget<CustomScrollView>(feedView).controller!;
      controller.jumpTo(400);
      await tester.pump();
      expect(controller.offset, 400);

      // Same-destination tap on the ranking bottom-bar slot: pure
      // scroll-to-top — no refresh, no re-request.
      final requestsBefore = fixture.requests.length;
      await tester.tap(
        find.descendant(
          of: find.byType(FuncShellBottomNav),
          matching: find.byIcon(AppIcons.ranking),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(controller.offset, 0);
      expect(fixture.requests.length, requestsBefore);
    });
  });
}
