import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pixiv_func/app/icons/app_icons.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/app/widgets/branch_slide_stack.dart';
import 'package:pixiv_func/app/widgets/func_bottom_nav.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/illust/ranking_repository.dart';
import 'package:pixiv_func/features/history/history_page.dart';
import 'package:pixiv_func/features/home/recommended/recommended_home_page.dart';
import 'package:pixiv_func/features/ranking/ranking_page.dart';
import 'package:pixiv_func/features/search/search_page.dart';
import 'package:pixiv_func/features/settings/settings_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

const _account = Account(id: '100', userId: 100, name: 'tester');

Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  String location = '/recommended',
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = createPixivRouter(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...accountProviderOverrides(
          credentialStore: FakeCredentialStore(
            values: const {
              '100': Credential(accessToken: 'a-100', refreshToken: 'r-100'),
            },
          ),
          metadataRepository: FakeAccountMetadataRepository(
            accounts: const [_account],
            currentId: '100',
          ),
        ),
      ],
      child: MaterialApp.router(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return router;
}

String _path(GoRouter router) => router.routeInformationProvider.value.uri.path;

/// A committed sideways flick inside the visible branch page.
Future<void> _flingLeft(WidgetTester tester, Finder page) =>
    tester.fling(page, const Offset(-260, 0), 900);
Future<void> _flingRight(WidgetTester tester, Finder page) =>
    tester.fling(page, const Offset(260, 0), 900);

TabController _tabController(WidgetTester tester, Finder page) => tester
    .widget<TabBar>(find.descendant(of: page, matching: find.byType(TabBar)))
    .controller!;

int _tabIndex(WidgetTester tester, Finder page) =>
    _tabController(tester, page).index;

void main() {
  testWidgets('sideways fling steps the top tabs first, then the branch', (
    tester,
  ) async {
    final router = await _pumpHome(tester);
    final page = find.byType(RecommendedHomePage);
    expect(_tabIndex(tester, page), 0);

    // Inner tabs: recommended has 4 — each fling advances one.
    for (var i = 1; i <= 3; i++) {
      await _flingLeft(tester, page);
      await tester.pumpAndSettle();
      expect(_tabIndex(tester, page), i);
      expect(_path(router), '/recommended');
    }

    // At the last top tab the same gesture carries over to the branch —
    // the nested-pager chain Shaft gets from its inner/outer ViewPagers.
    await _flingLeft(tester, page);
    await tester.pumpAndSettle();
    expect(_path(router), '/ranking');
  });

  testWidgets('a vertical fling never switches tabs or branches', (
    tester,
  ) async {
    final router = await _pumpHome(tester);
    await tester.fling(
      find.byType(RecommendedHomePage),
      const Offset(0, -300),
      1200,
    );
    await tester.pumpAndSettle();
    expect(_tabIndex(tester, find.byType(RecommendedHomePage)), 0);
    expect(_path(router), '/recommended');
  });

  testWidgets('a slow but deliberate sideways drag still switches', (
    tester,
  ) async {
    await _pumpHome(tester);
    // Distance past a quarter of the screen commits even without a fling.
    await tester.drag(
      find.byType(RecommendedHomePage),
      const Offset(-160, 0),
      touchSlopX: 18,
    );
    await tester.pumpAndSettle();
    expect(_tabIndex(tester, find.byType(RecommendedHomePage)), 1);
  });

  testWidgets('ranking walks all eleven modes, then the branch', (
    tester,
  ) async {
    final router = await _pumpHome(tester, location: '/ranking');
    final page = find.byType(RankingPage);
    // Jump the strip to its last mode — the next left fling must leave
    // the tab layer entirely.
    _tabController(tester, page).index = RankingMode.values.length - 1;
    await tester.pumpAndSettle();

    // Branch order is the bar's visual order: right of ranking sits new.
    await _flingLeft(tester, page);
    await tester.pumpAndSettle();
    expect(_path(router), '/new');
  });

  testWidgets('a page without top tabs goes straight to the branch', (
    tester,
  ) async {
    final router = await _pumpHome(tester, location: '/search');
    await _flingLeft(tester, find.byType(SearchHomePage));
    await tester.pumpAndSettle();
    expect(_path(router), '/settings');
  });

  testWidgets('the strip follows the finger, then settles or snaps back', (
    tester,
  ) async {
    await _pumpHome(tester);
    final controller = _tabController(tester, find.byType(RecommendedHomePage));

    // Finger down and travelling: the strip position tracks the drag —
    // 120px of 390 ≈ a third of the way to tab 1, no commit yet.
    final gesture = await tester.startGesture(const Offset(300, 400));
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(controller.animation!.value, greaterThan(0.05));
    expect(controller.animation!.value, lessThan(1.0));
    expect(controller.index, 0);

    // Released past the 25% commit bar: settles forward onto tab 1.
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.index, 1);

    // A short drag that stays under the bar springs back to the base tab.
    final weak = await tester.startGesture(const Offset(300, 400));
    await weak.moveBy(const Offset(-60, 0));
    await tester.pump();
    await weak.up();
    await tester.pumpAndSettle();
    expect(controller.index, 1);
    expect(controller.animation!.value, 1.0);
  });

  testWidgets('a branch drag slides the neighbour in under the finger', (
    tester,
  ) async {
    final router = await _pumpHome(tester, location: '/search');
    final pager = BranchSlideStack.maybeOf(
      tester.element(find.byType(SearchHomePage)),
    )!;
    // Search has no top tabs — the whole page is the sliding surface.
    final gesture = await tester.startGesture(const Offset(300, 400));
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();

    // Settings sits one branch right of search: it must already be
    // translating into view — a live slide, not a post-release swap.
    expect(pager.position, greaterThan(3.0));
    final settingsPage = find.byType(SettingsPage);
    expect(settingsPage, findsOneWidget);
    final slides = tester
        .widgetList<FractionalTranslation>(
          find.ancestor(
            of: settingsPage,
            matching: find.byType(FractionalTranslation),
          ),
        )
        .map((t) => t.translation.dx);
    expect(slides.any((dx) => dx > 0.0 && dx < 1.0), isTrue);
    expect(_path(router), '/search');

    // Releasing past the quarter-screen bar commits to the branch.
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_path(router), '/settings');
  });

  testWidgets('a short branch drag reels back', (tester) async {
    final router = await _pumpHome(tester, location: '/search');
    final pager = BranchSlideStack.maybeOf(
      tester.element(find.byType(SearchHomePage)),
    )!;
    final gesture = await tester.startGesture(const Offset(300, 400));
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_path(router), '/search');
    expect(pager.position, 3.0);
  });

  testWidgets('a bottom-bar tap slides the strip instead of snapping', (
    tester,
  ) async {
    final router = await _pumpHome(tester);
    final pagerContext = tester.element(find.byType(RecommendedHomePage));
    final pager = BranchSlideStack.maybeOf(pagerContext)!;

    // One shell-level bar above the strip — the settings destination is
    // its last item.
    await tester.tap(
      find.descendant(
        of: find.byType(FuncShellBottomNav),
        matching: find.byIcon(Icons.settings_outlined),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    // Mid-flight: the position is travelling, not already landed.
    expect(pager.position, greaterThan(0.0));
    expect(pager.position, lessThan(4.0));
    await tester.pumpAndSettle();
    expect(pager.position, 4.0);
    expect(_path(router), '/settings');
  });

  testWidgets('a mid-handoff reverse drag reels the branch strip back', (
    tester,
  ) async {
    // Regression: deltas after the outer pager took over used to freeze
    // its offset — a drag back only reeled in the tab strip and left the
    // branch page half-slid. With interception the whole touch belongs to
    // the branch pager, so reversing must walk it all the way home.
    final router = await _pumpHome(tester, location: '/search');
    final pager = BranchSlideStack.maybeOf(
      tester.element(find.byType(SearchHomePage)),
    )!;
    final gesture = await tester.startGesture(const Offset(300, 400));
    await gesture.moveBy(const Offset(-140, 0));
    await tester.pump();
    expect(pager.position, greaterThan(3.0));

    // Reverse past the origin — the strip follows the finger all the way
    // back instead of parking mid-slide.
    await gesture.moveBy(const Offset(160, 0));
    await tester.pump();
    expect(pager.position, lessThan(3.0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_path(router), '/search');
    expect(pager.position, 3.0);
  });

  testWidgets('the bottom bar stays fixed while the strip slides', (
    tester,
  ) async {
    await _pumpHome(tester, location: '/search');
    final pager = BranchSlideStack.maybeOf(
      tester.element(find.byType(SearchHomePage)),
    )!;
    final bar = find.byType(FuncShellBottomNav);
    final barTop = tester.getTopLeft(bar).dy;

    final gesture = await tester.startGesture(const Offset(300, 400));
    await gesture.moveBy(const Offset(-140, 0));
    await tester.pump();
    expect(pager.position, greaterThan(3.0));
    // The bar is the strip's sibling (Shaft's BottomNavigationView), not a
    // child of the sliding page — its edge must not have moved a pixel.
    expect(tester.getTopLeft(bar).dy, barTop);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('the first and last branches do not wrap', (tester) async {
    final router = await _pumpHome(tester, location: '/settings');
    final page = find.byType(SettingsPage);

    // Last branch: forward fling is a no-op.
    await _flingLeft(tester, page);
    await tester.pumpAndSettle();
    expect(_path(router), '/settings');

    // Backward fling walks back one branch — search sits left of
    // settings in the bar order.
    await _flingRight(tester, page);
    await tester.pumpAndSettle();
    expect(_path(router), '/search');
  });

  testWidgets('the bar indicator tracks the strip continuously', (
    tester,
  ) async {
    // Shaft parity: BottomNavigationView's selection follows
    // onPageScrolled, not onPageSelected — the underline must sit
    // between slots mid-drag, not jump after the warp.
    await _pumpHome(tester, location: '/search');
    final pager = BranchSlideStack.maybeOf(
      tester.element(find.byType(SearchHomePage)),
    )!;
    // The indicator is the lone Positioned inside the bar's Stack.
    final indicator = find.descendant(
      of: find.byType(FuncShellBottomNav),
      matching: find.byWidgetPredicate((w) => w is Positioned),
    );

    double indicatorCenter() {
      final positioned = tester.widget<Positioned>(indicator);
      return positioned.left! + positioned.width! / 2;
    }

    final slotWidth = tester.getSize(find.byType(FuncShellBottomNav)).width / 5;
    final rest = indicatorCenter();
    final gesture = await tester.startGesture(const Offset(300, 400));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    // Mid-drag the strip sits between slots; the indicator's centre must
    // have travelled the same fraction of a slot the strip travelled of
    // a page — tracking, not a jump after the midpoint warp.
    final movedPages = pager.position - 3.0;
    final movedPx = indicatorCenter() - rest;
    expect(movedPages, greaterThan(0.0));
    expect(movedPx, closeTo(movedPages * slotWidth, 8.0));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  group('re-tap channel', () {
    List<int> record(WidgetTester tester, Finder page) {
      final pager = BranchSlideStack.maybeOf(tester.element(page))!;
      final events = <int>[];
      pager.reTapEvents.addListener(() => events.add(pager.reTapEvents.branch));
      return events;
    }

    testWidgets('a same-destination tap emits one event per tap', (
      tester,
    ) async {
      await _pumpHome(tester);
      final events = record(tester, find.byType(RecommendedHomePage));

      await tester.tap(
        find.descendant(
          of: find.byType(FuncShellBottomNav),
          matching: find.byIcon(AppIcons.home),
        ),
      );
      await tester.pump();
      expect(events, [0]);

      // A repeat fires again — the event is an edge, not a state.
      await tester.tap(
        find.descendant(
          of: find.byType(FuncShellBottomNav),
          matching: find.byIcon(AppIcons.home),
        ),
      );
      await tester.pump();
      expect(events, [0, 0]);
    });

    testWidgets('a re-tap pops the branch stack back to its root', (
      tester,
    ) async {
      final router = await _pumpHome(tester);
      final pager = BranchSlideStack.maybeOf(
        tester.element(find.byType(RecommendedHomePage)),
      )!;
      final events = record(tester, find.byType(RecommendedHomePage));

      // Imperative pushes do not update the URL
      // (GoRouter.optionURLReflectsImperativeAPIs stays off), so the
      // pushed route is asserted through the widget tree instead of
      // routeInformationProvider. The history page keeps a spinner alive,
      // so bounded pumps drive the transition — never pumpAndSettle here.
      unawaited(router.push<void>('/recommended/history'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(HistoryPage), findsOneWidget);

      // The bar slides away while a pushed route covers the root, so the
      // tap arrives at the pager the same way FuncShellBottomNav sends it.
      pager.selectIndex(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.byType(HistoryPage), findsNothing);
      expect(find.byType(RecommendedHomePage), findsOneWidget);
      expect(events, [0]);
    });

    testWidgets('a different-destination tap does not emit', (tester) async {
      await _pumpHome(tester);
      final events = record(tester, find.byType(RecommendedHomePage));

      await tester.tap(
        find.descendant(
          of: find.byType(FuncShellBottomNav),
          matching: find.byIcon(AppIcons.search),
        ),
      );
      await tester.pumpAndSettle();
      expect(events, isEmpty);
    });

    testWidgets('syncIndex and drag settles never emit', (tester) async {
      final router = await _pumpHome(tester, location: '/search');
      final pager = BranchSlideStack.maybeOf(
        tester.element(find.byType(SearchHomePage)),
      )!;
      final events = record(tester, find.byType(SearchHomePage));

      // A committed drag settle crosses to the neighbour branch without
      // ever being a tap. Search has no top tabs, so the sideways drag is
      // the branch pager's directly.
      final gesture = await tester.startGesture(const Offset(300, 400));
      await gesture.moveBy(const Offset(-140, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_path(router), '/settings');
      expect(events, isEmpty);

      // A reel-back settle is also silent.
      final weak = await tester.startGesture(const Offset(300, 400));
      await weak.moveBy(const Offset(-60, 0));
      await tester.pump();
      await weak.up();
      await tester.pumpAndSettle();
      expect(events, isEmpty);

      // Programmatic sync: a deep link moves the shell, didUpdateWidget
      // runs the suppressed syncIndex path.
      router.go('/recommended');
      await tester.pumpAndSettle();
      expect(events, isEmpty);

      // Direct call — the early-return and animateTo paths alike.
      pager.syncIndex();
      await tester.pumpAndSettle();
      expect(events, isEmpty);
    });
  });
}
