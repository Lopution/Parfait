import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/features/profile/profile_statistics.dart';

ProfileStatisticData _stat(String id, String label, {VoidCallback? onTap}) =>
    ProfileStatisticData(
      id: id,
      icon: Icons.tag,
      label: label,
      value: 12,
      onTap: onTap,
    );

Finder _cell(String id) => find.byKey(ValueKey('profile-stat-$id-header'));

Future<void> _pumpGrid(
  WidgetTester tester, {
  required double width,
  required List<ProfileStatisticData> stats,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: replicaTheme(Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: ProfileStatisticsGrid(
              statistics: [
                for (final stat in stats)
                  ProfileStatistic(statistic: stat, compact: true),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Rows = distinct top offsets, in order of appearance.
List<double> _rowTops(WidgetTester tester, List<String> ids) {
  final tops = <double>{
    for (final id in ids) tester.getRect(_cell(id)).top,
  }.toList()..sort();
  return tops;
}

void main() {
  testWidgets('short labels fit six columns and share one row', (tester) async {
    final stats = [for (var i = 0; i < 6; i++) _stat('s$i', '关注')];
    await _pumpGrid(tester, width: 411, stats: stats);

    final tops = _rowTops(tester, [for (var i = 0; i < 6; i++) 's$i']);
    expect(tops, hasLength(1), reason: 'six short cells fit one row');

    final widths = [
      for (var i = 0; i < 6; i++) tester.getRect(_cell('s$i')).width,
    ];
    for (final width in widths) {
      expect(width, moreOrLessEquals(widths.first, epsilon: 0.01));
    }
  });

  testWidgets('a too-wide label drops the grid to three columns', (
    tester,
  ) async {
    // ~104dp intrinsic: fits a 3-column slot (~131dp) but not 6 (~61dp),
    // so the whole grid falls back to two rows of three.
    final stats = [
      _stat('wide', '比较长的统计标签'),
      for (var i = 0; i < 5; i++) _stat('s$i', '关注'),
    ];
    await _pumpGrid(tester, width: 411, stats: stats);

    final ids = ['wide', 's0', 's1', 's2', 's3', 's4'];
    final rects = [for (final id in ids) tester.getRect(_cell(id))];
    final topSet = rects.map((rect) => rect.top).toSet();
    expect(topSet, hasLength(2));
    for (final rect in rects) {
      expect(rect.width, moreOrLessEquals(rects.first.width, epsilon: 0.01));
    }
  });

  testWidgets('single column lets every cell take the full width', (
    tester,
  ) async {
    final stats = [
      _stat('wide', '非常非常长的标签标签标签标签标签标签标签标签标签'),
      _stat('s0', '关注'),
    ];
    await _pumpGrid(tester, width: 120, stats: stats);

    final wideRect = tester.getRect(_cell('wide'));
    final s0Rect = tester.getRect(_cell('s0'));
    expect(wideRect.top, isNot(s0Rect.top));
    expect(wideRect.width, moreOrLessEquals(120, epsilon: 0.01));
    expect(s0Rect.width, moreOrLessEquals(120, epsilon: 0.01));
  });

  testWidgets('cells stay tappable and no horizontal scroll is introduced', (
    tester,
  ) async {
    var tapped = 0;
    final stats = [
      for (var i = 0; i < 6; i++) _stat('s$i', '关注', onTap: () => tapped++),
    ];
    await _pumpGrid(tester, width: 411, stats: stats);

    await tester.tap(_cell('s2'));
    expect(tapped, 1);

    // R3: no horizontal Scrollable may appear above a stat cell.
    final element = tester.element(_cell('s0'));
    var hasHorizontalScrollable = false;
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Scrollable && widget.axis == Axis.horizontal) {
        hasHorizontalScrollable = true;
      }
      return true;
    });
    expect(hasHorizontalScrollable, isFalse);
  });
}
