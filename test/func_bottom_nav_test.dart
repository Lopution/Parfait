import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/app/widgets/func_bottom_nav.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/features/settings/settings_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

const _account = Account(id: '100', userId: 100, name: 'tester');

/// Pumps the real home shell — the bottom bar now lives one layer up in
/// [BranchSlideStack] (Shaft's sibling-of-ViewPager layout), so scroll-hide
/// behaviour can only be exercised through a real branch Navigator.
Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  String location = '/settings',
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
  of: find.byType(SettingsPage),
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
      home: Scaffold(
        bottomNavigationBar: FuncBottomNav(
          destinations: destinations,
          selectedIndex: selected,
          onSelected: onSelected ?? (_) {},
        ),
      ),
    );
  }

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

  testWidgets('branch switch landing replay settles cleanly', (tester) async {
    // A branch swap used to rebuild a per-branch bar with a new
    // selectedIndex — the didUpdateWidget path this exercises. The replay
    // spawns an InkHighlight + theme splash on the destination item,
    // holds ~130ms, then confirms/fades both.
    await tester.pumpWidget(host());
    await tester.pumpWidget(host(selected: 2));
    // Run the whole lifecycle: 130ms hold + splash fade + 200ms highlight
    // fade + margin. Any ticker leak, double registration, or teardown
    // assertion surfaces as an exception here.
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);

    // A rapid second switch while the first replay is still alive must
    // also settle: the pending features are released, not left ticking.
    await tester.pumpWidget(host(selected: 4));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(host(selected: 1));
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);
  });

  testWidgets('destinations ink matches the app bar TabBar', (tester) async {
    await tester.pumpWidget(host());
    final wells = tester.widgetList<InkWell>(find.byType(InkWell)).toList();
    expect(wells, hasLength(destinations.length));
    for (final well in wells) {
      // No splashFactory override: the items inherit the theme's splash —
      // the same InkSparkle the TabBar above resolves.
      expect(well.splashFactory, isNull);
      expect(well.overlayColor, isNotNull);
    }
  });

  testWidgets('indicator re-animates on every selection change', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
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

    double indicatorLeft() =>
        tester.widget<Positioned>(find.byType(Positioned)).left!;

    // Switch 0 -> 2: mid-flight the indicator is between positions.
    await tester.tap(find.text('新作'));
    await tester.pump(const Duration(milliseconds: 150));
    final midFirst = indicatorLeft();
    await tester.pumpAndSettle();
    final settledTwo = indicatorLeft();
    expect(midFirst, isNot(settledTwo));

    // Switch 2 -> 4 must animate again — previously a reused instance kept
    // a settled indicator because the animation never re-triggered.
    await tester.tap(find.text('我的'));
    await tester.pump(const Duration(milliseconds: 150));
    final midSecond = indicatorLeft();
    await tester.pumpAndSettle();
    expect(midSecond, isNot(indicatorLeft()));
    expect(midSecond, isNot(settledTwo));
  });

  testWidgets('long labels shrink uniformly instead of truncating', (
    tester,
  ) async {
    // 'Рекомендации' at 12pt is wider than a fifth of a 390px bar; every
    // label must render at one shared reduced size, fully readable.
    const ruDestinations = [
      FuncBottomNavDestination(
        icon: Icons.home_outlined,
        label: 'Рекомендации',
      ),
      FuncBottomNavDestination(icon: Icons.bar_chart, label: 'Рейтинг'),
      FuncBottomNavDestination(icon: Icons.new_releases, label: 'Новинки'),
      FuncBottomNavDestination(icon: Icons.search, label: 'Поиск'),
      FuncBottomNavDestination(icon: Icons.person_outline, label: 'Профиль'),
    ];
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: FuncBottomNav(
            destinations: ruDestinations,
            selectedIndex: 0,
            onSelected: (_) {},
          ),
        ),
      ),
    );

    final texts = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(FuncBottomNav),
            matching: find.byType(Text),
          ),
        )
        .toList();
    expect(texts, hasLength(ruDestinations.length));
    final sizes = texts.map((t) => t.style!.fontSize).toSet();
    // One shared size below the 12pt base — scaled, never ellipsized.
    expect(sizes, hasLength(1));
    expect(sizes.single, lessThan(12));
  });

  testWidgets('shell bar collapses on scroll down and returns on scroll up', (
    tester,
  ) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);
    final shownTop = tester.getTopLeft(nav).dy;
    expect(shownTop, lessThan(844));

    // Scroll down past the touch-slop threshold: the bar slides fully below
    // the screen edge — the layout never changes, the body was already
    // painted underneath.
    await tester.drag(_settingsList, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(844));

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
    final gesture = await tester.startGesture(
      tester.getCenter(_settingsList),
    );
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -120));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.getTopLeft(nav).dy, greaterThan(shownTop));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(844));
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
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(844));

    // Bottom edge: pull past the end and release. The spring-back deltas
    // must not resurrect the bar.
    gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, -150));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(844));
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
        PointerScrollEvent(
          position: center,
          scrollDelta: const Offset(0, -5),
        ),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));
  });
}
