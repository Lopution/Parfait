import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/core/network/data_worker.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/widgets/tab_swipe_switcher.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/features/ranking/ranking_page.dart';
import 'package:parfait/core/illust/ranking_repository.dart';
import 'package:parfait/core/network/api_date.dart';
import 'package:parfait/core/network/next_page_parser.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:parfait/core/illust/ranking_feed_controller.dart';
import 'package:parfait/core/ranking/ranking_catalog.dart';
import 'package:parfait/core/settings/settings_controller.dart';

import 'helpers/fake_account.dart';
import 'helpers/memory_feed_snapshot_store.dart';
import 'helpers/test_preferences.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';

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

  /// Re-armable gate: a pending request holds until [release]
  /// completes; assign a fresh Completer to block the next window
  /// (initial load vs. pull-to-refresh).
  Completer<void> release = Completer<void>();
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
    final accountOffset =
        request.headers['authorization'] == 'Bearer access-200' ? 100 : 0;
    final start = accountOffset + (isFirst ? 1 : 3);
    final nextMode = mismatchedNextMode?.apiValue ?? mode;
    // Pixiv echoes a past ranking's date into next_url.
    final date = request.url.queryParameters['date'];
    return http.Response(
      jsonEncode({
        'illusts': [
          for (var id = start; id < start + itemsPerPage; id++) _illust(id),
        ],
        'next_url': isFirst
            ? 'https://app-api.pixiv.net/v1/illust/ranking'
                  '?filter=for_android&mode=$nextMode'
                  '${date == null ? '' : '&date=$date'}&offset=30'
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
  MemoryFeedSnapshotStore? snapshots,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final activeFixture = fixture ?? _RankingFixture();
  final container = await signedInApiContainer(
    activeFixture.client(),
    others: [
      if (twoAccounts) const Account(id: '200', userId: 200, name: 'second'),
    ],
    overrides: [
      feedSnapshotStoreProvider.overrideWithValue(
        snapshots ?? MemoryFeedSnapshotStore(),
      ),
      // Snapshot writes encode inline so a test can await them.
      dataWorkerProvider.overrideWithValue(const InlineDataWorker()),
    ],
  );
  return (container, activeFixture);
}

/// The ranking route on a compact phone, settled.
Future<GoRouter> _pumpRanking(
  WidgetTester tester,
  ProviderContainer container, {
  TransitionBuilder? builder,
}) async {
  // Compact viewport: at ≥600px the shell swaps the bottom bar for a rail
  // and FuncShellBottomNav leaves the tree.
  setViewSize(tester, const Size(390, 844));
  final router = pixivRouter('/ranking');
  await tester.pumpWidget(
    localizedRouterApp(router, container: container, builder: builder),
  );
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
  return router;
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test('each mode has independent first page and load-more state', () async {
    final (container, fixture) = await _makeWorld();

    final day = await container.read(
      rankingFeedControllerProvider((mode: RankingMode.day, date: null)).future,
    );
    final week = await container.read(
      rankingFeedControllerProvider((
        mode: RankingMode.week,
        date: null,
      )).future,
    );
    expect(day.ids, [1, 2]);
    expect(week.ids, [1, 2]);
    expect(fixture.requests.map((uri) => uri.queryParameters['mode']), [
      'day',
      'week',
    ]);

    await container
        .read(
          rankingFeedControllerProvider((
            mode: RankingMode.day,
            date: null,
          )).notifier,
        )
        .loadMore();
    final dayAfter = container
        .read(
          rankingFeedControllerProvider((mode: RankingMode.day, date: null)),
        )
        .requireValue;
    final weekAfter = container
        .read(
          rankingFeedControllerProvider((mode: RankingMode.week, date: null)),
        )
        .requireValue;
    expect(dayAfter.ids, [1, 2, 3, 4]);
    expect(weekAfter.ids, [1, 2]);
    expect(weekAfter.exhausted, isFalse);
  });

  test('mismatched next mode is an observable parse error', () async {
    final (container, _) = await _makeWorld(
      fixture: (_RankingFixture()..mismatchedNextMode = RankingMode.week),
    );

    final state = await container.read(
      rankingFeedControllerProvider((mode: RankingMode.day, date: null)).future,
    );
    expect(state.showInitialError, isTrue);
    expect(state.initialError, isNotNull);
    expect(
      container
          .read(
            rankingFeedControllerProvider((
              mode: RankingMode.day,
              date: null,
            )).notifier,
          )
          .nextCursor,
      isNull,
    );
  });

  test(
    'account switching resets the mode controller and entity store',
    () async {
      final (container, fixture) = await _makeWorld(twoAccounts: true);

      final provider = rankingFeedControllerProvider((
        mode: RankingMode.day,
        date: null,
      ));
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

  group('ranking date', () {
    final pastDay = DateTime(2025, 10, 1);

    test('a past day is requested and paged with its date', () async {
      final (container, fixture) = await _makeWorld();
      final provider = rankingFeedControllerProvider((
        mode: RankingMode.day,
        date: pastDay,
      ));

      await container.read(provider.future);
      await container.read(provider.notifier).loadMore();

      expect(fixture.requests, hasLength(2));
      for (final request in fixture.requests) {
        expect(request.queryParameters['date'], '2025-10-01');
      }
    });

    test('a cursor from another day is rejected', () {
      NextPageRequest cursor(String query) => NextPageParser.parse(
        'https://app-api.pixiv.net/v1/illust/ranking?mode=day$query',
      )!;

      RankingRepository.validateModeCursor(
        cursor('&date=2025-10-01'),
        RankingMode.day,
        date: pastDay,
      );
      expect(
        () => RankingRepository.validateModeCursor(
          cursor('&date=2025-09-30'),
          RankingMode.day,
          date: pastDay,
        ),
        throwsA(isA<NextPageParseError>()),
      );
      expect(
        () => RankingRepository.validateModeCursor(
          cursor(''),
          RankingMode.day,
          date: pastDay,
        ),
        throwsA(isA<NextPageParseError>()),
      );
      expect(
        () => RankingRepository.validateModeCursor(
          cursor('&date=2025-10-01'),
          RankingMode.day,
        ),
        throwsA(isA<NextPageParseError>()),
      );
    });

    test('only the latest ranking writes the cold-start snapshot', () async {
      final snapshots = MemoryFeedSnapshotStore();
      final (container, _) = await _makeWorld(snapshots: snapshots);

      await container.read(
        rankingFeedControllerProvider((
          mode: RankingMode.day,
          date: pastDay,
        )).future,
      );
      await Future<void>.delayed(Duration.zero);
      expect(await snapshots.read('100', 'ranking:day'), isNull);
      expect(await snapshots.read('100', 'ranking:day@2025-10-01'), isNull);

      await container.read(
        rankingFeedControllerProvider((
          mode: RankingMode.day,
          date: null,
        )).future,
      );
      await Future<void>.delayed(Duration.zero);
      expect(await snapshots.read('100', 'ranking:day'), isNotNull);
    });

    test('pickable days run from the first ranking to yesterday in Japan', () {
      // 2026-10-05 02:00 in Japan is still 2026-10-04 in UTC.
      final now = DateTime.utc(2026, 10, 4, 17);
      expect(rankingLastDate(now: now), DateTime(2026, 10, 4));
      expect(rankingDateOrLatest(DateTime(2026, 10, 4), now: now), isNotNull);
      expect(rankingDateOrLatest(DateTime(2026, 10, 5), now: now), isNull);
      expect(rankingDateOrLatest(DateTime(2007, 9, 13), now: now), isNotNull);
      expect(rankingDateOrLatest(DateTime(2007, 9, 12), now: now), isNull);
    });

    Future<GoRouter> pumpRanking(
      WidgetTester tester,
      ProviderContainer container,
      String location,
    ) async {
      final router = pixivRouter(location);
      setViewSize(tester, const Size(390, 844));
      await tester.pumpWidget(localizedRouterApp(router, container: container));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('the route carries the day across modes and back to latest', (
      tester,
    ) async {
      final (container, fixture) = await _makeWorld();

      await mockNetworkImagesFor(() async {
        final router = await pumpRanking(
          tester,
          container,
          '/ranking?mode=day&date=2025-10-01',
        );
        expect(fixture.requests.last.queryParameters['mode'], 'day');
        expect(fixture.requests.last.queryParameters['date'], '2025-10-01');
        expect(find.textContaining('的排行'), findsOneWidget);

        await tester.tap(find.byType(Tab).at(1));
        await tester.pumpAndSettle();
        expect(router.state.uri.queryParameters['mode'], 'week');
        expect(router.state.uri.queryParameters['date'], '2025-10-01');
        expect(fixture.requests.last.queryParameters['mode'], 'week');
        expect(fixture.requests.last.queryParameters['date'], '2025-10-01');

        await tester.tap(find.text('回到最新'));
        await tester.pumpAndSettle();
        expect(router.state.uri.queryParameters['mode'], 'week');
        expect(router.state.uri.queryParameters.containsKey('date'), isFalse);
        expect(find.text('回到最新'), findsNothing);
        expect(
          fixture.requests.last.queryParameters.containsKey('date'),
          false,
        );
      });
    });

    for (final raw in ['2999-01-01', '2007-09-12', '2025-13-01', 'yesterday']) {
      testWidgets('date=$raw opens the latest ranking', (tester) async {
        final (container, fixture) = await _makeWorld();

        await mockNetworkImagesFor(() async {
          await pumpRanking(tester, container, '/ranking?mode=day&date=$raw');
        });
        expect(
          fixture.requests.single.queryParameters.containsKey('date'),
          false,
        );
        expect(find.text('回到最新'), findsNothing);
      });
    }

    testWidgets('the picker stops at yesterday in Japan', (tester) async {
      final (container, _) = await _makeWorld();

      await mockNetworkImagesFor(() async {
        final router = await pumpRanking(tester, container, '/ranking');
        // The date row of the category sheet.
        await tester.tap(find.byTooltip('全部分类'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('选择日期'));
        await tester.pumpAndSettle();

        final picker = tester.widget<DatePickerDialog>(
          find.byType(DatePickerDialog),
        );
        expect(picker.firstDate, DateTime(2007, 9, 13));
        expect(picker.lastDate, rankingLastDate());
        // Nothing picked yet: the dialog opens on the newest pickable day.
        expect(picker.initialDate, rankingLastDate());

        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(
          router.state.uri.queryParameters['date'],
          formatApiDate(rankingLastDate()),
        );
        expect(find.text('回到最新'), findsOneWidget);
      });
    });
  });

  test('cancel returns an active feed to idle without an error', () async {
    final fixture = _RankingFixture()..blockResponses = true;
    final (container, _) = await _makeWorld(fixture: fixture);

    final future = container.read(
      rankingFeedControllerProvider((mode: RankingMode.day, date: null)).future,
    );
    await Future<void>.delayed(Duration.zero);
    container
        .read(
          rankingFeedControllerProvider((
            mode: RankingMode.day,
            date: null,
          )).notifier,
        )
        .cancel();
    final state = await future;
    expect(state.initialPhase.name, 'idle');
    expect(state.initialError, isNull);
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
      await mockNetworkImagesFor(() async {
        final router = await _pumpRanking(
          tester,
          container,
          builder: (context, child) =>
              MotionScope(reduce: reduce, child: child!),
        );

        // Neighbour warm-up can interleave requests, so assert on the
        // request the landing produced (not merely the last one).
        int requestsFor(String apiMode) => fixture.requests
            .where((u) => u.queryParameters['mode'] == apiMode)
            .length;

        // Tap path: day → week. The strip animates (or snaps under
        // reduce) — either way the same mode lands and the durable
        // route value is written.
        final weekBefore = requestsFor('week');
        await tester.tap(find.byType(Tab).at(1));
        await tester.pumpAndSettle();
        expect(router.state.uri.queryParameters['mode'], 'week');
        expect(requestsFor('week'), greaterThan(weekBefore));

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
        expect(router.state.uri.queryParameters['mode'], 'week');
      });
    });
  }

  testWidgets('a mode swipe leaves the outgoing feed unbuilt', (tester) async {
    // The swipe hops the tab index mid-drag and echoes the mode into the
    // route; both rebuild the page. The feed sliding out must not rebuild
    // its cards for either — on device that landed inside the swipe frame.
    final (container, _) = await _makeWorld(
      fixture: _RankingFixture(itemsPerPage: 4),
    );
    await mockNetworkImagesFor(() async {
      final router = await _pumpRanking(tester, container);
      // The test host is desktop: SmoothWheelScroll leaves wheel mode on
      // the first pointer down and rebuilds its scrollable once. Spend that
      // on a short drag that does not commit.
      await tester.timedDrag(
        find.byType(TabSlideStack),
        const Offset(-40, 0),
        const Duration(milliseconds: 400),
      );
      await tester.pumpAndSettle();
      expect(router.state.uri.queryParameters['mode'], isNull);

      // The day feed's cards as mounted now; a later build of these same
      // elements is a rebuild.
      final dayCards = find.byType(IllustCard).evaluate().toSet();
      expect(dayCards, isNotEmpty);
      var cardRebuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (dayCards.contains(element)) cardRebuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      await tester.fling(
        find.byType(TabSlideStack),
        const Offset(-300, 0),
        1200,
      );
      await tester.pumpAndSettle();
      expect(router.state.uri.queryParameters['mode'], 'week');
      expect(cardRebuilds, 0);
    });
  });

  testWidgets('branch re-tap scrolls the active ranking feed to top', (
    tester,
  ) async {
    final (container, fixture) = await _makeWorld(
      fixture: _RankingFixture(itemsPerPage: 24),
    );
    await mockNetworkImagesFor(() async {
      await _pumpRanking(tester, container);

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

  group('category sheet', () {
    Finder inSheet(String text) => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text(text),
    );
    TabController tabs(WidgetTester tester) =>
        tester.widget<TabSlideStack>(find.byType(TabSlideStack)).controller;

    testWidgets('an edit updates the tabs, keeps the category and saves', (
      tester,
    ) async {
      final (container, _) = await _makeWorld();
      await mockNetworkImagesFor(() async {
        // R-18G is hidden by default: the link shows it first for the visit.
        final router = pixivRouter('/ranking?mode=weekR18G');
        setViewSize(tester, const Size(390, 844));
        await tester.pumpWidget(
          localizedRouterApp(router, container: container),
        );
        await tester.pumpAndSettle();
        expect(tabs(tester).index, 0);

        await tester.tap(find.byTooltip('全部分类'));
        await tester.pumpAndSettle();
        await tester.tap(inSheet('编辑'));
        await tester.pumpAndSettle();
        // A shown tile's tap hides it.
        await tester.tap(inSheet('每日'));
        await tester.pumpAndSettle();
        expect(
          container.read(illustRankingCatalog.arrangementProvider).hidden.first,
          RankingMode.day,
        );
        expect(find.widgetWithText(Tab, '每日'), findsNothing);
        expect(tabs(tester).index, 0, reason: 'R-18G still selected');
        expect(router.state.uri.queryParameters['mode'], 'weekR18G');

        // Shown, then hidden again: the selection moves to its neighbour,
        // and the sheet lists the page's tabs, not the ones it opened with.
        await tester.tap(inSheet('R-18G'));
        await tester.pumpAndSettle();
        expect(tabs(tester).index, 12);
        await tester.tap(inSheet('R-18G'));
        await tester.pumpAndSettle();
        expect(router.state.uri.queryParameters['mode'], 'dayFemaleR18');
        await tester.tap(inSheet('完成'));
        await tester.pumpAndSettle();
        expect(inSheet('R-18G'), findsNothing);

        await tester.tap(inSheet('每月'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect(router.state.uri.queryParameters['mode'], 'month');
        expect(tabs(tester).index, 1);
      });
    });

    testWidgets('an edit made from another branch waits to write the route', (
      tester,
    ) async {
      final (container, _) = await _makeWorld();
      await mockNetworkImagesFor(() async {
        final router = await _pumpRanking(tester, container);
        router.go('/settings');
        await tester.pumpAndSettle();
        // Hides the category on screen in the background ranking page.
        await illustRankingCatalog.saveArrangement(
          container.read(settingsProvider.notifier),
          RankingMode.defaultArrangement.hide(RankingMode.day),
        );
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/settings');

        await tester.tap(
          find.descendant(
            of: find.byType(FuncShellBottomNav),
            matching: find.byIcon(AppIcons.ranking),
          ),
        );
        await tester.pumpAndSettle();
        expect(router.state.uri.queryParameters['mode'], 'week');
      });
    });

    testWidgets('a ranking opened without a mode lands on the last one', (
      tester,
    ) async {
      final (container, fixture) = await _makeWorld();
      await mockNetworkImagesFor(() async {
        await _pumpRanking(tester, container);
        await tester.tap(find.byType(Tab).at(1));
        await tester.pumpAndSettle();
        // Saved when the app leaves the screen, not on the switch.
        expect(
          container.read(settingsProvider).value!.illustRankingLastMode,
          isNull,
        );
        tester.binding
          ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
          ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pumpAndSettle();
        expect(
          container.read(settingsProvider).value!.illustRankingLastMode,
          'week',
        );
        tester.binding
          ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
          ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);

        await tester.pumpWidget(const SizedBox());
        await _pumpRanking(tester, container);
        expect(tabs(tester).index, 1);
        expect(fixture.requests.last.queryParameters['mode'], 'week');
      });
    });
  });
}
