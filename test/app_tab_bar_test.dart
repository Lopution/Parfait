import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/motion/hero_transition.dart' show LiftableShadow;
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_tab_bar.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';

Widget _host(
  List<String> labels, {
  double textScale = 1,
  double? letterSpacing,
  ValueChanged<int>? onTap,
}) {
  return localizedApp(
    theme: replicaTheme(Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(
        textScaler: TextScaler.linear(textScale),
        letterSpacingOverride: letterSpacing,
      ),
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
  double? letterSpacing,
  ValueChanged<int>? onTap,
  double width = 411,
}) async {
  setViewSize(tester, Size(width, 800));
  await tester.pumpWidget(
    _host(
      labels,
      textScale: textScale,
      letterSpacing: letterSpacing,
      onTap: onTap,
    ),
  );
  await tester.pump();
}

RenderParagraph _label(WidgetTester tester, String label) =>
    tester.renderObject(
      find
          .descendant(
            of: find.ancestor(of: find.text(label), matching: find.byType(Tab)),
            matching: find.byType(RichText),
          )
          .first,
    );

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
      for (final label in labels) {
        final paragraph = _label(tester, label);
        expect((paragraph.text as TextSpan).style!.fontSize, 14, reason: label);
        // Shown whole: not squeezed into a slot and faded out.
        expect(
          paragraph.size.width,
          moreOrLessEquals(paragraph.getMaxIntrinsicWidth(double.infinity)),
          reason: label,
        );
      }
      // The first label sits at the start edge, within its label padding,
      // and a drag reaches the last one.
      final bar = tester.getRect(find.byType(TabBar));
      Rect tab(String label) => tester.getRect(
        find.ancestor(of: find.text(label), matching: find.byType(Tab)),
      );
      expect(
        tab(labels.first).left,
        inInclusiveRange(bar.left, bar.left + FuncSpacing.md),
      );
      await tester.drag(find.byType(TabBar), const Offset(-1000, 0));
      await tester.pumpAndSettle();
      expect(tab(labels.last).right, lessThanOrEqualTo(bar.right));
    }
  });

  testWidgets('a wide row keeps its tabs together at the start', (
    tester,
  ) async {
    const russian = ['Иллюстрации и манга', 'Романы', 'Пользователи', 'Теги'];
    for (final (labels, capped, letterSpacing) in const [
      (['插画', '漫画', '小说', '用户'], true, null),
      // A label wider than the cap widens every slot and is never cut,
      // also under the system's text spacing (WCAG 1.4.12: 0.12em).
      (russian, false, null),
      (russian, false, 1.7),
    ]) {
      await _pumpBar(tester, labels, width: 1400, letterSpacing: letterSpacing);

      final row = tester.getRect(find.byType(AppTabBar));
      final bar = tester.getRect(find.byType(TabBar));
      if (capped) {
        expect(bar.width, 4 * AppTabBar.maxSlotWidth);
      } else {
        expect(bar.width, greaterThan(4 * AppTabBar.maxSlotWidth));
        expect(bar.width, lessThan(row.width));
      }
      expect(bar.left, row.left);
      for (final label in labels) {
        final text = tester.renderObject<RenderParagraph>(find.text(label));
        expect(text.debugHasOverflowShader, isFalse, reason: label);
      }
    }
  });

  testWidgets(
    'a narrow row on a wide window keeps its tabs capped at the start',
    (tester) async {
      const labels = ['公开', '非公开'];
      setViewSize(tester, const Size(1280, 800));
      await tester.pumpWidget(
        localizedApp(
          theme: replicaTheme(Brightness.light),
          home: const DefaultTabController(
            length: 2,
            child: Scaffold(
              body: SizedBox(width: 500, child: AppTabBar(labels: labels)),
            ),
          ),
        ),
      );
      await tester.pump();

      // Capped on the window's form, not on the row: the slots do not
      // spread out just because this row is narrow.
      expect(
        tester.getRect(find.byType(TabBar)).width,
        2 * AppTabBar.maxSlotWidth,
      );
    },
  );

  testWidgets(
    'tabs beside the title share its row, the title alone the heading',
    (tester) async {
      final semantics = tester.ensureSemantics();
      setViewSize(tester, const Size(1280, 800));
      await tester.pumpWidget(
        localizedApp(
          theme: replicaTheme(Brightness.light),
          home: const DefaultTabController(
            length: 2,
            child: Scaffold(
              appBar: AppTopBar(
                title: Text('Bookmark tags'),
                tabsBesideTitle: true,
                bottom: AppTabBar(labels: ['公开', '非公开']),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // One toolbar row: the tabs did not add a second row under the title.
      expect(tester.getSize(find.byType(AppTopBar)).height, kToolbarHeight);
      final title = tester.getRect(find.text('Bookmark tags'));
      for (final label in ['公开', '非公开']) {
        // On the title's row, after it.
        expect(tester.getRect(find.text(label)).left, greaterThan(title.right));
      }
      // The heading is the title, not a node the tabs sit inside.
      for (
        SemanticsNode? node = tester.getSemantics(find.text('公开'));
        node != null;
        node = node.parent
      ) {
        expect(node.getSemanticsData().flagsCollection.isHeader, isFalse);
      }
      expect(
        tester.getSemantics(find.text('Bookmark tags')),
        isSemantics(label: 'Bookmark tags', isHeader: true, namesRoute: true),
      );
      semantics.dispose();
    },
  );

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
