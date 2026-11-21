import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/layout/form_factor.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/navigation/home_shell_metrics.dart';
import 'package:parfait/app/navigation/keyboard_back.dart';
import 'package:parfait/app/touch_exploration_scope.dart';
import 'package:parfait/app/widgets/app_snack_bar.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/home_branch_stack.dart';
import 'package:parfait/app/widgets/shell_rail.dart';
import 'package:parfait/app/window/desktop_command_bar_scope.dart';
import 'package:parfait/core/platform/accessibility.dart';
import 'package:parfait/core/ranking/ranking_catalog.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/history/history_page.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/illust/detail/widgets/detail_overlay_frame.dart';
import 'package:parfait/features/ranking/ranking_page.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/features/settings/me_dashboard_page.dart';

import 'helpers/fake_settings.dart';
import 'helpers/waits.dart';
import 'helpers/fake_account.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';
import 'package:parfait/app/icons/ui_icons.dart';

/// A split-screen phone height: the "me" dashboard at the root of the
/// settings branch fits a full phone screen and only scrolls on a short
/// one.
const _shortHeight = 480.0;

Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  String location = '/recommended',
  double width = 390,
  double height = 844,
  bool reduceMotion = false,
  Stream<bool> touchExploration = const Stream.empty(),
  bool firstFrameOnly = false,
  Size? display,
  bool desktopCommandBar = false,
}) async {
  setViewSize(tester, Size(width, height));
  if (display != null) setDisplaySize(tester, display);
  final router = pixivRouter(location);
  Widget app = localizedRouterApp(
    router,
    // The app's chrome: the form factor from the settings, Esc, touch
    // exploration, prompts.
    builder: (context, child) => Consumer(
      builder: (context, ref, _) {
        Widget inner = TouchExplorationScope(
          child: promptHostBuilder(context, child),
        );
        if (desktopCommandBar) {
          inner = DesktopCommandBarScope(active: true, child: inner);
        }
        return FormFactorScope(
          choice:
              ref.watch(settingsProvider).value?.interfaceForm ??
              InterfaceForm.auto,
          child: KeyboardBack(router: router, child: inner),
        );
      },
    ),
  );
  if (reduceMotion) {
    app = MotionScope(reduce: true, child: app);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...await signedInAccountOverrides(),
        touchExplorationProvider.overrideWith((ref) => touchExploration),
      ],
      child: app,
    ),
  );
  if (firstFrameOnly) return router;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return router;
}

Finder _barIcon(IconData icon) => find.descendant(
  of: find.byType(FuncShellBottomNav),
  matching: find.byIcon(icon),
);

List<int> _recordReTaps(WidgetTester tester, Finder page) {
  final channel = HomeBranchStack.reTapOf(tester.element(page))!;
  final events = <int>[];
  channel.addListener(() => events.add(channel.branch));
  return events;
}

/// The IgnorePointer HomeBranchStack puts around each branch child — the
/// one whose own child is the branch's ExcludeFocus, not any pointer guard
/// a route inside the branch Navigator may add.
IgnorePointer _branchPointer(WidgetTester tester, Finder page) => tester
    .widgetList<IgnorePointer>(
      find.ancestor(of: page, matching: find.byType(IgnorePointer)),
    )
    .singleWhere((w) => w.child is ExcludeFocus);

ExcludeSemantics _branchSemantics(WidgetTester tester, Finder page) => tester
    .widgetList<ExcludeSemantics>(
      find.ancestor(of: page, matching: find.byType(ExcludeSemantics)),
    )
    .singleWhere((w) => w.child is SlideTransition);

/// Drives the shell's shared tap entry the way FuncShellBottomNav does —
/// needed while a pushed route covers the current branch root and the bar
/// with it.
void _select(WidgetTester tester, int index) => tester
    .widget<FuncShellBottomNav>(find.byType(FuncShellBottomNav))
    .onSelected(index);

void main() {
  testWidgets('a bar tap slides the new branch in from its side', (
    tester,
  ) async {
    final router = await _pumpHome(tester);
    expect(find.byType(RankingPage), findsNothing);

    await tester.tap(_barIcon(AppIcons.ranking));
    await tester.pump();
    // Mid-flight both branches are on stage side by side — ranking sits
    // right of recommended on the bar, so it enters from the right — but
    // only the incoming one is hittable, has semantics and is marked
    // active for predictive back.
    await tester.pump(const Duration(milliseconds: 150));
    final recommended = find.byType(RecommendedHomePage);
    final ranking = find.byType(RankingPage);
    expect(recommended, findsOneWidget);
    expect(ranking, findsOneWidget);
    final incoming = tester.getTopLeft(ranking).dx;
    expect(incoming, inExclusiveRange(0, 390));
    expect(tester.getTopRight(recommended).dx, closeTo(incoming, 0.5));
    expect(_branchPointer(tester, recommended).ignoring, isTrue);
    expect(_branchPointer(tester, ranking).ignoring, isFalse);
    expect(_branchSemantics(tester, recommended).excluding, isTrue);
    expect(_branchSemantics(tester, ranking).excluding, isFalse);

    // Settled: the outgoing branch leaves the stage entirely.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(RecommendedHomePage), findsNothing);
    expect(
      find.byType(RecommendedHomePage, skipOffstage: false),
      findsOneWidget,
    );
    expect(ranking, findsOneWidget);
    expect(router.state.uri.path, '/ranking');
  });

  testWidgets('the incoming branch stays live while the outgoing one freezes', (
    tester,
  ) async {
    await _pumpHome(tester);
    // Still found once the switch has put it offstage.
    final recommended = find.byType(RecommendedHomePage, skipOffstage: false);
    bool tickersOn(Finder page) =>
        TickerMode.valuesOf(tester.element(page)).enabled;
    // The branch's own snapshot, right under its slide, above the route
    // snapshots inside the branch Navigator.
    bool snapshotting(Finder page) =>
        (tester
                    .widgetList<SlideTransition>(
                      find.ancestor(
                        of: page,
                        matching: find.byType(
                          SlideTransition,
                          skipOffstage: false,
                        ),
                      ),
                    )
                    .singleWhere((w) => w.child is SnapshotWidget)
                    .child!
                as SnapshotWidget)
            .controller
            .allowSnapshotting;
    expect(tickersOn(recommended), isTrue);
    expect(snapshotting(recommended), isFalse);

    await tester.tap(_barIcon(AppIcons.ranking));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final ranking = find.byType(RankingPage);
    // Outgoing branch: frozen texture. Incoming branch: live.
    expect(tickersOn(recommended), isFalse);
    expect(tickersOn(ranking), isTrue);
    expect(snapshotting(recommended), isTrue);
    expect(snapshotting(ranking), isFalse);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(tickersOn(ranking), isTrue);
    expect(snapshotting(ranking), isFalse);
  });

  testWidgets('each branch keeps its stack and scroll position', (
    tester,
  ) async {
    final router = await _pumpHome(tester);

    // A route pushed inside the recommended branch survives switches.
    unawaited(router.push<void>('/recommended/history'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(HistoryPage), findsOneWidget);

    _select(tester, 4);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(MeDashboardPage), findsOneWidget);

    // Open the settings index on this branch, scroll it, then leave.
    unawaited(router.push<void>('/settings/all'));
    await tester.pumpAndSettle();
    final list = find.descendant(
      of: find.byType(SettingsPage),
      matching: find.bySubtype<ListView>(),
    );
    await tester.drag(list, const Offset(0, -120));
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byType(SettingsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(position, greaterThan(0));

    // Back to recommended: the pushed page is still on top of its stack.
    _select(tester, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(HistoryPage), findsOneWidget);

    // And the settings list kept its scroll offset.
    _select(tester, 4);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(tester.state<ScrollableState>(scrollable).position.pixels, position);
  });

  testWidgets('a resize keeps every branch, its stack and its scroll', (
    tester,
  ) async {
    final router = await _pumpHome(tester);
    final recommended = tester.state(find.byType(RecommendedHomePage));
    _select(tester, 4);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    unawaited(router.push<void>('/settings/all'));
    await tester.pumpAndSettle();
    final settings = find.byType(SettingsPage);
    await tester.drag(
      find.descendant(of: settings, matching: find.bySubtype<ListView>()),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    double offset() => tester
        .state<ScrollableState>(
          find
              .descendant(of: settings, matching: find.byType(Scrollable))
              .first,
        )
        .position
        .pixels;
    final scrolled = offset();

    // Unfolding: the rail replaces the bottom bar around the same branches.
    setViewSize(tester, const Size(1280, 800));
    await tester.pumpAndSettle();
    expect(find.byType(ShellRail), findsOneWidget);
    expect(offset(), scrolled);
    expect(
      tester.state(find.byType(RecommendedHomePage, skipOffstage: false)),
      same(recommended),
    );
  });

  testWidgets('Esc goes back as the system back does, short of leaving', (
    tester,
  ) async {
    final router = await _pumpHome(tester);
    unawaited(router.push<void>('/recommended/search/input'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    bool editing() =>
        primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() !=
        null;
    expect(editing(), isTrue);

    // The first Esc only leaves the field; the next one leaves the page.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(editing(), isFalse);
    expect(find.byType(SearchInputPage), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(SearchInputPage), findsNothing);
    expect(find.byType(RecommendedHomePage), findsOneWidget);

    // The first destination's root: nothing to go back to, the app stays.
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(calls.map((c) => c.method), isNot(contains('SystemNavigator.pop')));
    expect(find.byType(RecommendedHomePage), findsOneWidget);
  });

  testWidgets('a branch built ahead and never shown saves no setting on '
      'leaving', (tester) async {
    await _pumpHome(tester, firstFrameOnly: true);
    final ranking = find.byType(RankingPage, skipOffstage: false);
    await pumpUntil(
      tester,
      () => ranking.evaluate().isNotEmpty,
      step: const Duration(milliseconds: 16),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(ranking));
    expect(container.read(illustRankingCatalog.lastViewedProvider), isNull);
  });

  testWidgets('a switch before its turn builds the branch at once', (
    tester,
  ) async {
    await _pumpHome(tester, firstFrameOnly: true);
    await tester.tap(_barIcon(AppIcons.search));
    await tester.pump();
    expect(find.byType(SearchHomePage), findsOneWidget);
  });

  group('re-tap channel', () {
    testWidgets('a same-destination tap emits one event per tap', (
      tester,
    ) async {
      await _pumpHome(tester);
      final events = _recordReTaps(tester, find.byType(RecommendedHomePage));

      await tester.tap(_barIcon(AppIcons.homeFilled));
      await tester.pump();
      expect(events, [0]);

      // A repeat fires again — the event is an edge, not a state.
      await tester.tap(_barIcon(AppIcons.homeFilled));
      await tester.pump();
      expect(events, [0, 0]);
    });

    testWidgets('a re-tap pops the branch stack back to its root', (
      tester,
    ) async {
      final router = await _pumpHome(tester);
      final events = _recordReTaps(tester, find.byType(RecommendedHomePage));

      // Imperative pushes do not update the URL
      // (GoRouter.optionURLReflectsImperativeAPIs stays off), so the
      // pushed route is asserted through the widget tree instead of
      // routeInformationProvider. The history page keeps a spinner alive,
      // so bounded pumps drive the transition — never pumpAndSettle here.
      unawaited(router.push<void>('/recommended/history'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(HistoryPage), findsOneWidget);

      // The pushed route covers the bar, so the tap arrives at the stack
      // the same way FuncShellBottomNav sends it.
      _select(tester, 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.byType(HistoryPage), findsNothing);
      expect(find.byType(RecommendedHomePage), findsOneWidget);
      expect(events, [0]);
    });
  });

  // Within a screen the scroll grows from 300 to 500 ms with the distance;
  // farther, the list jumps to a screen from the top and takes 500 ms.
  for (final (from, firstFrameAt, ms) in [
    (300.0, 300.0, 400),
    (5000.0, 600.0, 500),
  ]) {
    testWidgets('a re-tap from $from scrolls home in $ms ms', (tester) async {
      final controller = ScrollController(initialScrollOffset: from);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            height: 600,
            child: ListView.builder(
              controller: controller,
              itemExtent: 100,
              itemCount: 100,
              itemBuilder: (_, i) => Text('$i'),
            ),
          ),
        ),
      );
      reTapScrollToTop(tester.element(find.bySubtype<ListView>()), controller);
      await tester.pump();
      expect(controller.offset, firstFrameAt);
      await tester.pump(Duration(milliseconds: ms - 10));
      expect(controller.offset, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 20));
      expect(controller.offset, 0);
    });
  }

  group('a swipe between destinations', () {
    /// Bounded: the history page keeps a spinner running.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
    }

    int barBranch(WidgetTester tester) => tester
        .widget<FuncShellBottomNav>(find.byType(FuncShellBottomNav))
        .currentBranch;

    testWidgets('takes over from the tabs at their last one', (tester) async {
      await _pumpHome(tester);
      final recommended = find.byType(RecommendedHomePage);
      for (var i = 0; i < 3; i++) {
        await tester.fling(recommended, const Offset(-260, 0), 900);
        await settle(tester);
      }
      expect(barBranch(tester), 0, reason: 'the tabs took the first three');

      // On the last tab the branches follow the finger; the bar's
      // selection moves only when they land.
      final gesture = await tester.startGesture(tester.getCenter(recommended));
      for (var i = 0; i < 25; i++) {
        await gesture.moveBy(const Offset(-10, 0));
        await tester.pump();
      }
      final peer = find.byType(RankingPage);
      final peerLeft = peer.evaluate().isEmpty
          ? null
          : tester.getTopLeft(peer).dx;
      final barMidway = barBranch(tester);
      await gesture.up();
      await settle(tester);
      expect(peerLeft, lessThan(200));
      expect(barMidway, 0);
      expect(barBranch(tester), 1);
      expect(find.byType(RecommendedHomePage), findsNothing);

      // Back from the ranking's first tab: home keeps its last tab.
      await tester.fling(find.byType(RankingPage), const Offset(260, 0), 900);
      await settle(tester);
      expect(barBranch(tester), 0);
      final tabs = tester.widget<TabBar>(
        find.descendant(of: recommended, matching: find.byType(TabBar)),
      );
      expect(tabs.controller!.index, 3);
    });

    testWidgets(
      'a page without tabs pages at once; the end of the bar bounces',
      (tester) async {
        await _pumpHome(tester, location: '/settings');
        final me = find.byType(MeDashboardPage);
        await tester.fling(me, const Offset(-260, 0), 900);
        await settle(tester);
        expect(barBranch(tester), 4);
        expect(tester.getTopLeft(me).dx, 0);

        await tester.fling(me, const Offset(260, 0), 900);
        await settle(tester);
        expect(barBranch(tester), 3);
        expect(find.byType(SearchHomePage), findsOneWidget);
      },
    );

    // A page still leaving no longer counts as one the branch can pop,
    // yet the root draws the bar until it has gone: the bar slid away with
    // the branch, and the next one came in without it.
    for (final (name, width, height) in [
      ('a pushed page', 390.0, 844.0),
      ('the rail', 896.0, 411.0),
      ('a page still leaving', 390.0, 844.0),
    ]) {
      testWidgets('$name keeps its destination', (tester) async {
        final router = await _pumpHome(tester, width: width, height: height);
        var page = find.byType(RecommendedHomePage);
        if (width < 600) {
          unawaited(router.push<void>('/recommended/history'));
          await settle(tester);
          page = find.byType(HistoryPage);
        }
        if (name == 'a page still leaving') {
          router.pop();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          page = find.byType(RecommendedHomePage);
          final tabs = tester.widget<TabBar>(
            find.descendant(of: page, matching: find.byType(TabBar)),
          );
          tabs.controller!.index = tabs.controller!.length - 1;
        }
        await tester.fling(page, const Offset(-260, 0), 900);
        await settle(tester);
        expect(find.byType(RankingPage), findsNothing);
        expect(page, findsOneWidget);
      });
    }
  });

  testWidgets('a turned phone keeps the bottom bar', (tester) async {
    await _pumpHome(
      tester,
      width: 896,
      height: 411,
      display: const Size(411, 896),
    );

    expect(find.byType(ShellRail), findsNothing);
    expect(find.byType(FuncShellBottomNav), findsOneWidget);
    // No rail to subtract: pages lay out for the whole window, so the
    // detail page's two panes stay.
    expect(
      HomeShellChrome.contentSizeOf(
        tester.element(find.byType(RecommendedHomePage)),
      ),
      const Size(896, 411),
    );
  });

  testWidgets('a short window on a tablet gets a scrolling icon rail', (
    tester,
  ) async {
    await _pumpHome(
      tester,
      width: 896,
      height: 411,
      display: const Size(1280, 800),
    );

    // Five labelled destinations and two shortcuts overflowed 411dp before
    // the rail scrolled. A touch screen's rail stays collapsed, the app's
    // icon on top.
    expect(tester.takeException(), isNull);
    final rail = find.byType(ShellRail);
    expect(tester.getSize(rail).width, ShellRail.width);
    expect(
      find.descendant(of: rail, matching: find.byType(Scrollable)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rail, matching: find.byType(IconButton)),
      findsNothing,
    );
    // Its destinations read as the bottom bar's do.
    expect(
      tester.getSemantics(
        find.descendant(of: rail, matching: find.byIcon(AppIcons.homeFilled)),
      ),
      isSemantics(
        role: SemanticsRole.tab,
        isSelected: true,
        hasSelectedState: true,
        label: '推荐\n第 1 个标签，共 5 个',
      ),
    );
  });

  testWidgets('a PC rail stays expanded across rail widths without a collapse '
      'toggle', (tester) async {
    await _pumpHome(tester, width: 1200, height: 900);
    final rail = find.byType(ShellRail);
    double railWidth() => tester.getSize(rail).width;
    expect(railWidth(), ShellRail.expandedWidth);
    expect(
      HomeShellChrome.contentSizeOf(
        tester.element(find.byType(RecommendedHomePage)),
      ).width,
      1200 - ShellRail.expandedWidth,
    );
    expect(find.byTooltip('收起侧栏'), findsNothing);
    expect(find.byTooltip('展开侧栏'), findsNothing);

    setViewSize(tester, const Size(700, 700));
    await tester.pumpAndSettle();
    expect(railWidth(), ShellRail.expandedWidth);
    expect(find.byTooltip('收起侧栏'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
    'a toggleable tablet rail opens and closes by width rather than in one frame',
    (tester) async {
      await _pumpHome(
        tester,
        width: 1200,
        height: 900,
        display: const Size(1200, 900),
      );
      final rail = find.byType(ShellRail);
      double railWidth() => tester.getSize(rail).width;
      expect(railWidth(), ShellRail.width);

      await tester.tap(find.byTooltip('展开侧栏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        railWidth(),
        inExclusiveRange(ShellRail.width, ShellRail.expandedWidth),
      );
      await tester.pumpAndSettle();
      expect(railWidth(), ShellRail.expandedWidth);

      await tester.tap(find.byTooltip('收起侧栏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        railWidth(),
        inExclusiveRange(ShellRail.width, ShellRail.expandedWidth),
      );
      await tester.pumpAndSettle();
      expect(railWidth(), ShellRail.width);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('with reduced motion a toggleable rail changes width at once', (
    tester,
  ) async {
    await _pumpHome(
      tester,
      width: 1200,
      height: 900,
      display: const Size(1200, 900),
      reduceMotion: true,
    );
    final rail = find.byType(ShellRail);
    await tester.tap(find.byTooltip('展开侧栏'));
    await tester.pump();
    expect(tester.getSize(rail).width, ShellRail.expandedWidth);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'turning reduced motion on mid-slide lands a toggleable rail at once',
    (tester) async {
      await _pumpHome(
        tester,
        width: 1200,
        height: 900,
        display: const Size(1200, 900),
      );
      final rail = find.byType(ShellRail);
      double railWidth() => tester.getSize(rail).width;
      await tester.tap(find.byTooltip('展开侧栏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        railWidth(),
        inExclusiveRange(ShellRail.width, ShellRail.expandedWidth),
      );

      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      expect(railWidth(), ShellRail.expandedWidth);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('the interface form changes the shell at once and keeps the '
      'open page', (tester) async {
    final router = await _pumpHome(tester, width: 1280, height: 800);
    unawaited(router.push<void>('/recommended/history'));
    await tester.pumpAndSettle();
    final history = tester.state(find.byType(HistoryPage));
    final rail = find.byType(ShellRail);
    expect(tester.getSize(rail).width, ShellRail.expandedWidth);
    expect(find.byTooltip('收起侧栏'), findsNothing);

    await ProviderScope.containerOf(
      tester.element(rail),
    ).read(settingsProvider.notifier).setInterfaceForm(InterfaceForm.touch);
    await tester.pumpAndSettle();
    // Wide touch (>= 840x480) keeps the rail collapsed by default while still
    // offering the manual expand toggle (`NAV-20`).
    expect(tester.getSize(rail).width, ShellRail.width);
    expect(find.byTooltip('展开侧栏'), findsOneWidget);
    expect(tester.state(find.byType(HistoryPage)), same(history));

    await tester.tap(find.byTooltip('展开侧栏'));
    await tester.pumpAndSettle();
    expect(tester.getSize(rail).width, ShellRail.expandedWidth);
    expect(find.byTooltip('收起侧栏'), findsOneWidget);

    // Narrower touch (< 840dp) collapses back and hides the toggle button.
    setViewSize(tester, const Size(700, 800));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开侧栏'), findsNothing);
    expect(
      find.descendant(of: rail, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(tester.state(find.byType(HistoryPage)), same(history));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('beside the rail, the downloads and the profile open in the '
      'branch and the rail stays', (tester) async {
    final router = await _pumpHome(tester, width: 1280, height: 800);
    final rail = find.byType(ShellRail);
    String location() => router.state.uri.toString();

    await tester.tap(
      find.descendant(of: rail, matching: find.byIcon(AppIcons.downloading)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DownloadTasksPage), findsOneWidget);
    expect(location(), '/recommended/downloads');
    expect(rail.hitTestable(), findsOneWidget);

    await tester.tap(
      find.descendant(of: rail, matching: find.byIcon(AppIcons.heart)),
    );
    await tester.pumpAndSettle();
    expect(location(), '/recommended/me?tab=bookmarks');
    expect(rail.hitTestable(), findsOneWidget);
  });

  testWidgets('a prompt centres on the content beside the rail', (
    tester,
  ) async {
    await _pumpHome(tester, width: 1280, height: 800);
    showAppSnackBar(
      tester.element(find.byType(RecommendedHomePage)),
      '已保存',
      duration: const Duration(seconds: 30),
    );
    await tester.pumpAndSettle();
    // As the sheets are, in the content area, not the whole window.
    expect(
      tester.getCenter(promptCard('已保存')).dx,
      (1280 + ShellRail.width) / 2,
    );
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
  });

  group('the rail shares the bar action entry', () {
    testWidgets('a same-destination rail tap pops the branch stack and '
        'emits re-tap', (tester) async {
      final router = await _pumpHome(tester, width: 900);
      final events = _recordReTaps(tester, find.byType(RecommendedHomePage));

      unawaited(router.push<void>('/recommended/history'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(HistoryPage), findsOneWidget);

      // The rail stays mounted while a pushed route covers the branch —
      // a tap here used to die on goBranch's same-index no-op. Through
      // the shared entry it is the bar's re-tap: pop to root + emit.
      await tester.tap(
        find.descendant(
          of: find.byType(ShellRail),
          matching: find.byIcon(AppIcons.homeFilled),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.byType(HistoryPage), findsNothing);
      expect(find.byType(RecommendedHomePage), findsOneWidget);
      expect(events, [0]);
    });
  });

  group('touch exploration', () {
    final settingsList = find.descendant(
      of: find.byType(MeDashboardPage),
      matching: find.bySubtype<ListView>(),
    );

    testWidgets('the bottom bar stays on screen while scrolling', (
      tester,
    ) async {
      await _pumpHome(
        tester,
        location: '/settings',
        height: _shortHeight,
        touchExploration: Stream.value(true),
      );
      final nav = find.byType(FuncBottomNav);
      final shownTop = tester.getTopLeft(nav).dy;

      // A TalkBack user cannot find a bar that slid off screen, so the
      // scroll-hide path is parked while touch exploration is on.
      await tester.drag(settingsList, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));
    });

    testWidgets('starting touch exploration brings a hidden bar back', (
      tester,
    ) async {
      final exploration = StreamController<bool>();
      addTearDown(exploration.close);
      await _pumpHome(
        tester,
        location: '/settings',
        height: _shortHeight,
        touchExploration: exploration.stream,
      );
      final nav = find.byType(FuncBottomNav);
      final shownTop = tester.getTopLeft(nav).dy;

      // Hide with a real scroll first.
      await tester.drag(settingsList, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_shortHeight));

      exploration.add(true);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));
    });

    testWidgets('a polluted engine flag does not pin the bar', (tester) async {
      // GKD reads nodes constantly, which sets the engine's
      // accessibleNavigation bit — but it is not touch exploration, so the
      // bar still hides on scroll.
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _pumpHome(
        tester,
        location: '/settings',
        height: _shortHeight,
        touchExploration: Stream.value(false),
      );
      final nav = find.byType(FuncBottomNav);

      await tester.drag(settingsList, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_shortHeight));
    });
  });

  testWidgets(
    'ShellRail dims behind bounded DetailOverlayFrame and dismisses on tap',
    (tester) async {
      final router = await _pumpHome(tester, width: 1180, height: 820);
      const railScrimKey = ValueKey('home-rail-modal-scrim');
      expect(find.byKey(railScrimKey), findsNothing);

      unawaited(router.push<void>('/recommended/illust/42'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('detail-overlay-scrim')),
        findsOneWidget,
      );
      expect(find.byKey(railScrimKey), findsOneWidget);
      final scrimBox = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byKey(railScrimKey),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(scrimBox.color, const Color(0x990C0B0E));
      expect(find.byIcon(UiIcons.close), findsOneWidget);

      await tester.tap(find.byKey(railScrimKey));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/recommended');
      expect(find.byKey(railScrimKey), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'wide HomePage modal scrim starts at 0.0 on frame 0 and decays monotonically on pop or interrupt',
    (tester) async {
      final router = await _pumpHome(tester, width: 1280, height: 800);
      const railScrimKey = ValueKey('home-rail-modal-scrim');

      double? entryOpacity() {
        final frames = find.byType(DetailOverlayFrame).evaluate();
        if (frames.isEmpty) return null;
        final entries = HomeShellChrome.maybeOf(
          frames.first,
        )?.modalScrim?.activeEntries;
        if (entries == null || entries.isEmpty) return null;
        return entries.last.opacity;
      }

      double renderedScrimProgress() {
        final boxes = tester.widgetList<ColoredBox>(
          find.descendant(
            of: find.byKey(railScrimKey),
            matching: find.byType(ColoredBox),
          ),
        );
        if (boxes.isEmpty) return 0.0;
        return boxes.single.color.a / const Color(0x990C0B0E).a;
      }

      // Frame 0 of push: scrim starts at 0.0 (never flashes 1.0).
      unawaited(router.push<void>('/recommended/illust/42'));
      await tester.pump();
      expect(renderedScrimProgress(), 0.0);
      expect(entryOpacity() ?? 0.0, 0.0);

      // Mid-entrance: strictly inside (0, 1).
      await tester.pump(const Duration(milliseconds: 120));
      final midEntry = entryOpacity()!;
      expect(midEntry, greaterThan(0.0));
      expect(midEntry, lessThan(1.0));
      expect(renderedScrimProgress(), greaterThan(0.0));
      expect(renderedScrimProgress(), lessThan(1.0));

      // Interrupt mid-push: frame 1 stays > 0 and decays monotonically.
      router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final interrupt1 = entryOpacity()!;
      expect(interrupt1, greaterThan(0.0));
      expect(interrupt1, lessThan(midEntry));
      expect(renderedScrimProgress(), greaterThan(0.0));
      await tester.pump(const Duration(milliseconds: 16));
      final interrupt2 = entryOpacity()!;
      expect(interrupt2, greaterThan(0.0));
      expect(interrupt2, lessThan(interrupt1));
      await tester.pumpAndSettle();
      expect(find.byKey(railScrimKey), findsNothing);

      // Full push -> settled 1.0 -> normal pop decays monotonically from > 0.
      unawaited(router.push<void>('/recommended/illust/42'));
      await tester.pumpAndSettle();
      expect(entryOpacity(), 1.0);
      expect(renderedScrimProgress(), closeTo(1.0, 0.01));

      router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final pop1 = entryOpacity()!;
      expect(pop1, greaterThan(0.0));
      expect(pop1, lessThan(1.0));
      expect(renderedScrimProgress(), greaterThan(0.0));
      await tester.pump(const Duration(milliseconds: 16));
      final pop2 = entryOpacity()!;
      expect(pop2, greaterThan(0.0));
      expect(pop2, lessThan(pop1));
      await tester.pumpAndSettle();
      expect(find.byKey(railScrimKey), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'tablet landscape auto-collapses expanded ShellRail on Me and Settings',
    (tester) async {
      final router = await _pumpHome(
        tester,
        width: 1180,
        height: 820,
        display: const Size(1180, 820),
      );
      final rail = find.byType(ShellRail);
      await tester.tap(find.byTooltip('展开侧栏'));
      await tester.pumpAndSettle();
      expect(tester.getSize(rail).width, ShellRail.expandedWidth);

      await tester.tap(find.descendant(of: rail, matching: find.text('我的')));
      await tester.pumpAndSettle();
      expect(tester.getSize(rail).width, ShellRail.width);

      unawaited(router.push<void>('/settings/all'));
      await tester.pumpAndSettle();
      expect(tester.getSize(rail).width, ShellRail.width);

      await tester.tap(find.descendant(of: rail, matching: find.text('推荐')));
      await tester.pumpAndSettle();
      expect(tester.getSize(rail).width, ShellRail.expandedWidth);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'desktop ShellRail animates branch switch with 150ms fade+slide',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        setViewSize(tester, const Size(1280, 800));
        await seedSettings(AppSettings.defaults());
        final router = pixivRouter('/recommended');
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...await signedInAccountOverrides(),
              touchExplorationProvider.overrideWith(
                (ref) => const Stream.empty(),
              ),
            ],
            child: localizedRouterApp(
              router,
              builder: (_, child) => FormFactorScope(
                choice: InterfaceForm.auto,
                child: TouchExplorationScope(child: child!),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        router.go('/ranking');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 70));
        expect(find.byType(RankingPage), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 90));
        await tester.pump();
        final rankingSlide = tester.widget<SlideTransition>(
          find
              .ancestor(
                of: find.byType(RankingPage),
                matching: find.byType(SlideTransition),
              )
              .first,
        );
        expect(rankingSlide.position.value, Offset.zero);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'desktop rail cycles 3-state theme and keeps Me, Bookmarks, Downloads, and Settings mutually exclusive',
    (tester) async {
      final router = await _pumpHome(
        tester,
        width: 1280,
        height: 800,
        desktopCommandBar: true,
      );
      final rail = find.byType(ShellRail);
      final container = ProviderScope.containerOf(tester.element(rail));
      expect(tester.getSize(rail).width, ShellRail.expandedWidth);
      expect(container.read(themeModeProvider), ThemeMode.system);
      expect(
        find.descendant(
          of: find.byKey(const Key('rail-theme-toggle')),
          matching: find.byIcon(UiIcons.devices),
        ),
        findsOneWidget,
      );

      // Cycle system -> light -> dark -> system.
      await tester.tap(find.byKey(const Key('rail-theme-toggle')));
      await tester.pumpAndSettle();
      expect(container.read(themeModeProvider), ThemeMode.light);
      expect(
        find.descendant(
          of: find.byKey(const Key('rail-theme-toggle')),
          matching: find.byIcon(AppIcons.sun),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('rail-theme-toggle')));
      await tester.pumpAndSettle();
      expect(container.read(themeModeProvider), ThemeMode.dark);
      expect(
        find.descendant(
          of: find.byKey(const Key('rail-theme-toggle')),
          matching: find.byIcon(AppIcons.moon),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('rail-theme-toggle')));
      await tester.pumpAndSettle();
      expect(container.read(themeModeProvider), ThemeMode.system);

      // From Recommended, clicking Bookmarks / Downloads / Settings highlights
      // only that entry (never Me simultaneously) and Back returns to Recommended.
      await tester.tap(find.byKey(const Key('rail-bookmarks')));
      await tester.pumpAndSettle();
      expect(router.state.uri.toString(), '/settings/me?tab=bookmarks');
      expect(tester.widget<ShellRail>(rail).bookmarksSelected, isTrue);
      expect(tester.widget<ShellRail>(rail).downloadsSelected, isFalse);
      expect(tester.widget<ShellRail>(rail).settingsSelected, isFalse);

      await tester.tap(find.byKey(const Key('rail-downloads')));
      await tester.pumpAndSettle();
      expect(router.state.uri.toString(), '/settings/downloads');
      expect(tester.widget<ShellRail>(rail).bookmarksSelected, isFalse);
      expect(tester.widget<ShellRail>(rail).downloadsSelected, isTrue);

      await tester.tap(find.byKey(const Key('rail-settings')));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/settings/all');
      expect(tester.widget<ShellRail>(rail).settingsSelected, isTrue);
      expect(tester.getSize(rail).width, ShellRail.expandedWidth);

      await router.routerDelegate.popRoute();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/recommended');

      // Visiting Me directly omits duplicate Bookmarks & Downloads rows inside
      // wide desktop MeDashboardPage.
      await tester.tap(find.descendant(of: rail, matching: find.text('我的')));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/settings');
      expect(tester.getSize(rail).width, ShellRail.expandedWidth);
      expect(
        find.descendant(
          of: find.byType(MeDashboardPage),
          matching: find.text('下载任务'),
        ),
        findsNothing,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
