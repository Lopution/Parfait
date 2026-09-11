import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pixiv_func/app/layout/app_breakpoints.dart';
import 'package:pixiv_func/app/theme/replica_theme.dart';
import 'package:pixiv_func/app/widgets/feed/feed_grid.dart';

void main() {
  test('illustColumnsFor derives columns from the available extent', () {
    // Widths from the acceptance matrix: 320/390/600/840/1200 + landscape.
    expect(illustColumnsFor(320), 2);
    expect(illustColumnsFor(390), 2);
    expect(illustColumnsFor(600), 3);
    expect(illustColumnsFor(840), 4);
    expect(illustColumnsFor(1200), 6);
    expect(illustColumnsFor(1600), 8);
    // Degenerate extents never go below two columns.
    expect(illustColumnsFor(0), 2);
    expect(illustColumnsFor(-50), 2);
  });

  test('navigation form factor follows the compact/medium breakpoint', () {
    expect(AppBreakpoints.useNavigationRail(320), isFalse);
    expect(AppBreakpoints.useNavigationRail(390), isFalse);
    expect(AppBreakpoints.useNavigationRail(599), isFalse);
    expect(AppBreakpoints.useNavigationRail(600), isTrue);
    expect(AppBreakpoints.useNavigationRail(840), isTrue);
    expect(AppBreakpoints.useNavigationRail(1200), isTrue);
  });

  testWidgets(
    'IllustFeedGrid counts columns on the sliver extent, not the window',
    (tester) async {
      // Window is 800 logical px; the grid is embedded next to a fixed 400px
      // rail-like pane, so its content extent is ~400 — two columns, not the
      // four the window width would imply.
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: replicaTheme(Brightness.light),
          home: Scaffold(
            body: Row(
              children: [
                const SizedBox(width: 400),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      IllustFeedGrid(
                        itemCount: 4,
                        itemBuilder: (context, index) =>
                            const SizedBox(height: 40),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final grid = tester.widget<SliverMasonryGrid>(
        find.byType(SliverMasonryGrid),
      );
      final delegate =
          grid.gridDelegate
              as SliverSimpleGridDelegateWithFixedCrossAxisCount;
      // 400 - 2*10 horizontal padding = 380 -> floor(380/180) = 2.
      expect(delegate.crossAxisCount, 2);
    },
  );
}
