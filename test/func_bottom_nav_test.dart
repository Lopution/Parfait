import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pixiv_func/app/widgets/func_bottom_nav.dart';

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

  testWidgets('destinations ripple through InkWell like app bar buttons', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    expect(find.byType(InkWell), findsNWidgets(destinations.length));
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
}
