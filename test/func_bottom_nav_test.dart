import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pixiv_func/app/widgets/func_bottom_nav.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

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
    // A branch swap rebuilds this bar with a new selectedIndex — the same
    // didUpdateWidget path FuncBranchBottomNav drives on goBranch. The
    // replay spawns an InkHighlight + theme splash on the destination
    // item, holds ~130ms, then confirms/fades both.
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

  testWidgets('branch bar collapses on scroll down and returns on scroll up', (
    tester,
  ) async {
    // The default 800×600 surface is medium-width → rail layout, no bar.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BranchRootScaffold(
            branchIndex: 0,
            child: ListView.builder(
              itemCount: 80,
              itemBuilder: (_, i) =>
                  SizedBox(height: 60, child: Text('row $i')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final nav = find.byType(FuncBranchBottomNav);
    final fullHeight = tester.getSize(nav).height;
    expect(fullHeight, greaterThan(0));

    // Scroll down past the touch-slop threshold: the bar must shrink to zero
    // height, freeing the layout space rather than overlaying it.
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getSize(nav).height, 0);

    // Scrolling back up restores it.
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(tester.getSize(nav).height, closeTo(fullHeight, 0.5));
  });

  testWidgets('short scrolls below the slop keep the bar expanded', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BranchRootScaffold(
            branchIndex: 0,
            child: ListView.builder(
              itemCount: 80,
              itemBuilder: (_, i) =>
                  SizedBox(height: 60, child: Text('row $i')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final nav = find.byType(FuncBranchBottomNav);
    final fullHeight = tester.getSize(nav).height;

    // Alternating small drags never cross the accumulated threshold.
    for (var i = 0; i < 3; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.drag(find.byType(ListView), const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pumpAndSettle();
    expect(tester.getSize(nav).height, closeTo(fullHeight, 0.5));
  });
}
