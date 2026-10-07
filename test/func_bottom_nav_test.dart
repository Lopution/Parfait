import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:parfait/app/navigation/home_shell_metrics.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/fit_label.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/features/settings/me_dashboard_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';

const _account = Account(id: '100', userId: 100, name: 'tester');

/// A split-screen phone height: the "me" dashboard at the root of the
/// settings branch fits a full phone screen and only scrolls on a short
/// one.
const _screenHeight = 480.0;

/// Pumps the real home shell — the bottom bar now lives one layer up in
/// [HomeBranchStack] (a sibling of the branch stack), so scroll-hide
/// behaviour can only be exercised through a real branch Navigator.
Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  String location = '/settings',
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  tester.view.physicalSize = const Size(390, _screenHeight);
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
        builder: promptHostBuilder,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  // Settle the entry transition: a half-run ModalRoute keeps its modal
  // barrier hit-testable, which swallows drags aimed at the page.
  await tester.pumpAndSettle();
  // A prior testWidgets in the same process can leave a pushed route in
  // the branch Navigator (e.g. /settings/translate). Force the branch
  // back to its root so the harness always starts from a clean stack.
  router.go(location);
  await tester.pumpAndSettle();
  return router;
}

Finder get _settingsList => find.descendant(
  of: find.byType(MeDashboardPage),
  matching: find.byType(ListView),
);

void main() {
  const destinations = [
    FuncBottomNavDestination(icon: Icons.home_outlined, label: '推荐'),
    FuncBottomNavDestination(icon: Icons.bar_chart, label: '排行'),
    FuncBottomNavDestination(icon: Icons.new_releases, label: '新作'),
    FuncBottomNavDestination(icon: Icons.search, label: '搜索'),
    FuncBottomNavDestination(icon: Icons.person_outline, label: '我的'),
  ];

  Widget host({int selected = 0, ValueChanged<int>? onSelected}) {
    return MaterialApp(
      builder: promptHostBuilder,
      home: Scaffold(
        bottomNavigationBar: FuncBottomNav(
          destinations: destinations,
          selectedIndex: selected,
          onSelected: onSelected ?? (_) {},
        ),
      ),
    );
  }

  Finder indicatorAt(int index) => find
      .descendant(
        of: find.byType(FuncBottomNav),
        matching: find.byType(NavigationIndicator),
      )
      .at(index);

  /// The pill's painted X scale: 1 fully grown, 0 absent.
  double pillScale(WidgetTester tester, int index) => tester
      .widget<Transform>(
        find.descendant(
          of: indicatorAt(index),
          matching: find.byType(Transform),
        ),
      )
      .transform
      .storage[0];

  testWidgets('renders every destination label', (tester) async {
    await tester.pumpWidget(host());
    for (final d in destinations) {
      expect(find.text(d.label), findsOneWidget);
    }
  });

  testWidgets('tapping a destination reports its index', (tester) async {
    var tapped = -1;
    await tester.pumpWidget(host(onSelected: (i) => tapped = i));
    await tester.tap(find.text('搜索'));
    expect(tapped, 3);
  });

  testWidgets('a 56x32 pill sits behind only the selected icon', (
    tester,
  ) async {
    await tester.pumpWidget(host(selected: 1));
    await tester.pumpAndSettle();
    for (var i = 0; i < destinations.length; i++) {
      expect(
        tester.getSize(
          find.descendant(of: indicatorAt(i), matching: find.byType(Ink)),
        ),
        FuncBottomNav.indicatorSize,
      );
      expect(pillScale(tester, i), i == 1 ? 1.0 : 0.0);
    }
  });

  testWidgets('the pill grows from the centre on selection', (tester) async {
    var selected = 0;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          builder: promptHostBuilder,
          home: Scaffold(
            bottomNavigationBar: FuncBottomNav(
              destinations: destinations,
              selectedIndex: selected,
              onSelected: (i) => setState(() => selected = i),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('新作'));
    // The selection controllers start on the tap's rebuild frame; the next
    // frame lands mid-flight, the arriving pill part-grown and the
    // leaving one part-shrunk.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(pillScale(tester, 2), greaterThan(0));
    expect(pillScale(tester, 0), lessThan(1));
    await tester.pumpAndSettle();
    expect(pillScale(tester, 2), 1.0);
    expect(pillScale(tester, 0), 0.0);
  });

  testWidgets('destinations carry tab, selected and tabLabel semantics', (
    tester,
  ) async {
    await tester.pumpWidget(host(selected: 2));
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.role == ui.SemanticsRole.tab &&
            w.properties.selected == true,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.role == ui.SemanticsRole.tab &&
            w.properties.selected == false,
      ),
      findsNWidgets(destinations.length - 1),
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.button == true,
      ),
      findsNWidgets(destinations.length),
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Tab 1 of 5',
      ),
      findsOneWidget,
    );
  });

  testWidgets('labels draw at most 1.3x platform text scale', (tester) async {
    Future<double> paintedScale(double platformScale) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: promptHostBuilder,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(platformScale)),
              child: Scaffold(
                bottomNavigationBar: FuncBottomNav(
                  destinations: destinations,
                  selectedIndex: 0,
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('推荐'));
      return text.textScaler!.scale(12);
    }

    // 12sp at 1.3x = 15.6 logical px; at 2.0x the bar's own clamp must
    // produce the same value instead of 24.
    expect(await paintedScale(1.3), moreOrLessEquals(15.6));
    expect(await paintedScale(2.0), moreOrLessEquals(15.6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ink is confined to the pill', (tester) async {
    await tester.pumpWidget(host());
    // find.byType never hits subclasses — the destinations use a private
    // InkResponse type, so match by `is` instead.
    final inks = tester
        .widgetList<InkResponse>(
          find.descendant(
            of: find.byType(FuncBottomNav),
            matching: find.byWidgetPredicate((w) => w is InkResponse),
          ),
        )
        .toList();
    expect(inks, hasLength(destinations.length));
    for (final ink in inks) {
      // No splashFactory override: the items inherit the theme's splash.
      expect(ink.splashFactory, isNull);
      expect(ink.overlayColor, isNotNull);
      expect(ink.containedInkWell, isTrue);
      expect(ink.highlightColor, Colors.transparent);
      expect(ink.customBorder, isA<StadiumBorder>());
      final rect = ink.getRectCallback(
        tester.renderObject<RenderBox>(find.byWidget(ink)),
      )!();
      expect(rect.size, FuncBottomNav.indicatorSize);
    }
  });

  Future<void> pumpBar(
    WidgetTester tester,
    List<FuncBottomNavDestination> bar, {
    int selected = 0,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: promptHostBuilder,
        home: Scaffold(
          bottomNavigationBar: FuncBottomNav(
            destinations: bar,
            selectedIndex: selected,
            onSelected: (_) {},
          ),
        ),
      ),
    );
  }

  List<FitLabel> fitLabels(WidgetTester tester) => tester
      .widgetList<FitLabel>(
        find.descendant(
          of: find.byType(FuncBottomNav),
          matching: find.byType(FitLabel),
        ),
      )
      .toList();

  // 'Рекомендации' at 12pt is far wider than a fifth of a 390px bar in
  // FlutterTest's square glyphs.
  const ruDestinations = [
    FuncBottomNavDestination(icon: Icons.home_outlined, label: 'Рекомендации'),
    FuncBottomNavDestination(icon: Icons.bar_chart, label: 'Рейтинг'),
    FuncBottomNavDestination(icon: Icons.new_releases, label: 'Новинки'),
    FuncBottomNavDestination(icon: Icons.search, label: 'Поиск'),
    FuncBottomNavDestination(icon: Icons.person_outline, label: 'Профиль'),
  ];

  testWidgets('long labels share one scale, floored at 0.8, then ellipsize '
      'with the full text in a tooltip', (tester) async {
    await pumpBar(tester, ruDestinations);
    final labels = fitLabels(tester);
    expect(labels, hasLength(ruDestinations.length));
    final fits = labels.map((label) => label.fit).toSet();
    expect(fits, hasLength(1));
    expect(fits.single.scale, LabelFit.minScale);
    expect(fits.single.truncates, isTrue);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Рекомендации',
      ),
      findsOneWidget,
    );
  });

  testWidgets('labels that fit keep their size', (tester) async {
    await pumpBar(tester, destinations);
    expect(fitLabels(tester).map((label) => label.fit).toSet(), {
      LabelFit.none,
    });
  });

  testWidgets('shell bar collapses on scroll down and returns on scroll up', (
    tester,
  ) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);
    final shownTop = tester.getTopLeft(nav).dy;
    expect(shownTop, lessThan(_screenHeight));

    // Scroll down past the touch-slop threshold: the bar slides fully below
    // the screen edge — the layout never changes, the body was already
    // painted underneath.
    await tester.drag(_settingsList, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));

    // Scrolling back up restores it.
    await tester.drag(_settingsList, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));
  });

  testWidgets('bar collapses mid-drag, not on release', (tester) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);
    final shownTop = tester.getTopLeft(nav).dy;

    // Finger still down: crossing the slop mid-drag must already slide the
    // bar out — waiting for release would mean only the ballistic phase
    // counts. Time is advanced in frames: a single large pump step does
    // not tick controllers while a pointer is held.
    final gesture = await tester.startGesture(tester.getCenter(_settingsList));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -120));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.getTopLeft(nav).dy, greaterThan(shownTop));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));
  });

  testWidgets('a continuous drag slides the bar out under the finger', (
    tester,
  ) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);

    // Every frame's move crosses the slop and asks for the hide again; the
    // slide must keep its own clock instead of restarting on each ask, so
    // it finishes within a drag that outlasts MotionTokens.navBarHide.
    final gesture = await tester.startGesture(tester.getCenter(_settingsList));
    await gesture.moveBy(const Offset(0, -20));
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('edge bounce never toggles the bar', (tester) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);
    final shownTop = tester.getTopLeft(nav).dy;
    final list = _settingsList;

    // Top edge: pull down into overscroll and release. The spring-back
    // replays positive deltas which must not hide the bar.
    var gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, 150));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));

    // Hide the bar with a real scroll, land at the bottom edge.
    await tester.drag(list, const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));

    // Bottom edge: pull past the end and release. The spring-back deltas
    // must not resurrect the bar.
    gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, -150));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));
  });

  testWidgets('the shell bar publishes its live visible extent', (
    tester,
  ) async {
    await _pumpHome(tester);
    final chrome = HomeShellChrome.of(
      tester.element(find.byType(MeDashboardPage)),
    );
    final extent = chrome.bottomBarExtent;
    expect(extent, greaterThan(0));
    expect(chrome.bottomBarVisibleExtent.value, closeTo(extent, 0.001));

    // Scrolling down slides the bar out; the published extent shrinks in
    // step with the animation instead of snapping.
    await tester.drag(_settingsList, const Offset(0, -200));
    var sawPartial = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final v = chrome.bottomBarVisibleExtent.value;
      if (v == 0) break;
      if (v < extent) sawPartial = true;
    }
    expect(sawPartial, isTrue);
    await tester.pumpAndSettle();
    expect(chrome.bottomBarVisibleExtent.value, 0);

    await tester.drag(_settingsList, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(chrome.bottomBarVisibleExtent.value, closeTo(extent, 0.001));
  });

  testWidgets('short scrolls below the slop keep the bar expanded', (
    tester,
  ) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);
    final shownTop = tester.getTopLeft(nav).dy;

    // Alternating sub-slop deltas never cross the accumulated threshold.
    // They must arrive as wheel ticks: a touch drag small enough to stay
    // under the bar's ~8px slop can never claim the Scrollable's own 18px
    // slop, and a release inside slop lands as a *tap* on whatever tile
    // sits under the pointer — pushing a route and legitimately hiding
    // the bar. PointerScrollEvent applies its delta directly, no arena.
    final center = tester.getCenter(_settingsList);
    for (var i = 0; i < 3; i++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 5)),
      );
      await tester.pump(const Duration(milliseconds: 60));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, -5)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));
  });
}
