import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/motion/hero_transition.dart' show LiftableShadow;
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_tab_bar.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';

Widget _host(
  List<String> labels, {
  double textScale = 1,
  ValueChanged<int>? onTap,
}) {
  return localizedApp(
    theme: replicaTheme(Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        appBar: AppBar(
          title: DefaultTabController(
            length: labels.length,
            child: AppTabBar(labels: labels, onTap: onTap),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpBar(
  WidgetTester tester,
  List<String> labels, {
  double textScale = 1,
  ValueChanged<int>? onTap,
  double width = 411,
}) async {
  setViewSize(tester, Size(width, 800));
  await tester.pumpWidget(_host(labels, textScale: textScale, onTap: onTap));
  await tester.pump();
}

RichText _labelRichText(WidgetTester tester, String label) {
  return tester.widget<RichText>(
    find
        .descendant(
          of: find.ancestor(of: find.text(label), matching: find.byType(Tab)),
          matching: find.byType(RichText),
        )
        .first,
  );
}

void main() {
  testWidgets('labels that do not fit scroll from the start at 14sp', (
    tester,
  ) async {
    // Eleven labels, and four long ones at a 1.3x text scale.
    for (final (labels, textScale) in [
      (
        const [
          '插画',
          '漫画',
          '小说',
          '推荐',
          '排行',
          '新作',
          '追更',
          '收藏',
          '历史',
          '发现',
          '关于',
        ],
        1.0,
      ),
      (const ['每日排行', '昨日排行', '每周排行', '每月排行'], 1.3),
    ]) {
      await _pumpBar(tester, labels, textScale: textScale);
      expect(tester.takeException(), isNull);
      final bar = tester.widget<TabBar>(find.byType(TabBar));
      expect(bar.isScrollable, isTrue);
      expect(bar.tabAlignment, TabAlignment.start);
      expect(
        (_labelRichText(tester, labels.first).text as TextSpan).style!.fontSize,
        14,
      );
    }
  });

  testWidgets('a wide row keeps its tabs together at the start', (
    tester,
  ) async {
    await _pumpBar(tester, const ['插画', '漫画', '小说', '用户'], width: 1400);

    final row = tester.getRect(find.byType(AppTabBar));
    final bar = tester.getRect(find.byType(TabBar));
    expect(bar.width, 4 * AppTabBar.maxSlotWidth);
    expect(bar.left, row.left);
    expect(tester.widget<TabBar>(find.byType(TabBar)).isScrollable, isFalse);
  });

  testWidgets(
    'a top bar with tabs casts its shadow once content scrolls under it',
    (tester) async {
      setViewSize(tester, const Size(411, 800));
      await tester.pumpWidget(
        localizedApp(
          theme: replicaTheme(Brightness.light),
          home: DefaultTabController(
            length: 2,
            child: Scaffold(
              appBar: const AppTopBar(
                title: Text('追更'),
                bottom: AppTabBar(labels: ['漫画', '小说']),
              ),
              body: ListView(
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 60, child: Text('row $i')),
                ],
              ),
            ),
          ),
        ),
      );
      final shadow = find.descendant(
        of: find.byType(ScrollEdgeShadow),
        matching: find.byType(AnimatedOpacity),
      );
      double opacity() => tester.widget<AnimatedOpacity>(shadow).opacity;
      expect(opacity(), 0);

      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(opacity(), 1);
      final cast = tester.widget<LiftableShadow>(
        find.descendant(of: shadow, matching: find.byType(LiftableShadow)),
      );
      // Cast down, over the content under the bar, as the bottom bar's goes up.
      expect(
        cast.shadows.map((s) => s.offset.dy),
        everyElement(greaterThan(0)),
      );

      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(opacity(), 0);
    },
  );
}
