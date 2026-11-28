import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/layout/form_factor.dart';
import 'package:parfait/app/navigation/forward_history.dart';
import 'package:parfait/app/navigation/home_shell_metrics.dart';
import 'package:parfait/app/navigation/keyboard_back.dart';
import 'package:parfait/app/touch_exploration_scope.dart';
import 'package:parfait/app/widgets/fit_label.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/home_branch_stack.dart';
import 'package:parfait/app/widgets/shell_rail.dart';
import 'package:parfait/app/window/desktop_command_bar_scope.dart';
import 'package:parfait/core/navigation/home_destination.dart';
import 'package:parfait/core/platform/accessibility.dart';
import 'package:parfait/core/ranking/ranking_catalog.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/history/history_page.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/ranking/ranking_page.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/features/settings/me_dashboard_page.dart';

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
  Stream<bool> touchExploration = const Stream.empty(),
  bool firstFrameOnly = false,
  Size? display,
  bool desktopCommandBar = false,
}) async {
  setViewSize(tester, Size(width, height));
  if (display != null) setDisplaySize(tester, display);
  final router = pixivRouter(location);
  final app = localizedRouterApp(
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

/// Drives the shell's shared tap entry the way FuncShellBottomNav does —
/// needed while a pushed route covers the current branch root and the bar
/// with it.
void _select(WidgetTester tester, int index) => tester
    .widget<FuncShellBottomNav>(find.byType(FuncShellBottomNav))
    .onSelected(index);

void main() {
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

      // Cycle system -> light -> dark -> system without shifting primary nav label scale.
      final navLabelScaleBefore = tester
          .widget<FitLabel>(
            find.ancestor(
              of: find.descendant(of: rail, matching: find.text('推荐')),
              matching: find.byType(FitLabel),
            ),
          )
          .fit
          .scale;
      await tester.tap(find.byKey(const Key('rail-theme-toggle')));
      await tester.pumpAndSettle();
      expect(container.read(themeModeProvider), ThemeMode.light);
      expect(
        tester
            .widget<FitLabel>(
              find.ancestor(
                of: find.descendant(of: rail, matching: find.text('推荐')),
                matching: find.byType(FitLabel),
              ),
            )
            .fit
            .scale,
        navLabelScaleBefore,
      );
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

      // NAV-03 parity: Back is disabled on start branch root, enabled on non-start branch root.
      final history = ForwardHistoryStack.ofRouter(router);
      expect(history.canGoBack, isFalse);
      history.selectHomeDestination(HomeDestination.ranking);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/ranking');
      expect(history.canGoBack, isTrue);
      await history.goBack();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/recommended');
      expect(history.canGoBack, isFalse);

      // From Recommended, clicking Bookmarks / Downloads / Settings highlights
      // only that entry (never Me simultaneously) and Back returns to Recommended
      // without polluting the settings branch's forward history.
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

      // Explicit shortcut/menu selection of Me clears _returnBranch (no bounce-back).
      history.selectHomeDestination(HomeDestination.me);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/settings');

      history.selectHomeDestination(HomeDestination.recommended);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('rail-settings')));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/settings/all');
      expect(tester.widget<ShellRail>(rail).settingsSelected, isTrue);
      expect(tester.getSize(rail).width, ShellRail.expandedWidth);

      await router.routerDelegate.popRoute();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/recommended');
      expect(history.canGoForward, isFalse);

      // Visiting Me directly omits duplicate Bookmarks & Downloads rows inside
      // wide desktop MeDashboardPage and keeps no stale forward entry.
      await tester.tap(find.descendant(of: rail, matching: find.text('我的')));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/settings');
      expect(history.canGoForward, isFalse);
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
