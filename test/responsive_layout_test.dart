import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/layout/card_columns.dart';
import 'package:parfait/app/layout/content_widths.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'helpers/view_size.dart';

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

  test('card lists take a column per 400dp, at most three', () {
    expect(CardColumns.of(390), 1);
    expect(CardColumns.of(815), 2);
    expect(CardColumns.of(1199), 2);
    expect(CardColumns.of(1359), 3);
    expect(CardColumns.of(2400), 3);
    expect(CardColumns.rowCount(5, 2), 3);
  });

  testWidgets('a wide card list puts neighbouring cards side by side', (
    tester,
  ) async {
    setViewSize(tester, const Size(1000, 600));
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            SliverCardList(
              itemCount: 3,
              itemBuilder: (context, index) =>
                  SizedBox(key: ValueKey(index), height: 80),
            ),
          ],
        ),
      ),
    );

    Rect card(int index) => tester.getRect(find.byKey(ValueKey(index)));
    expect(card(1).top, card(0).top);
    expect(card(1).left, card(0).right);
    expect(card(2).top, card(0).bottom);
    expect(card(2).width, 500);
  });

  testWidgets('a capped column centres at its width on a wide window', (
    tester,
  ) async {
    setViewSize(tester, const Size(1400, 600));
    await tester.pumpWidget(
      const ContentWidthCap(
        maxWidth: ContentWidths.management,
        child: SizedBox.expand(key: Key('column')),
      ),
    );

    final column = tester.getRect(find.byKey(const Key('column')));
    expect(column.width, ContentWidths.management);
    expect(column.center.dx, 700);
  });

  testWidgets(
    'IllustFeedGrid counts columns on the sliver extent, not the window',
    (tester) async {
      // Window is 800 logical px; the grid is embedded next to a fixed 400px
      // rail-like pane, so its content extent is ~400 — two columns, not the
      // four the window width would imply.
      setViewSize(tester, const Size(800, 600));

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
          grid.gridDelegate as SliverSimpleGridDelegateWithFixedCrossAxisCount;
      // 400 - 2*10 horizontal padding = 380 -> floor(380/180) = 2.
      expect(delegate.crossAxisCount, 2);
    },
  );

  // Device crash in flutter_staggered_grid_view 0.7.0: a refresh that moves
  // works still on screen to the head of the list, while the grid is
  // scrolled, left the head child without a layout offset once the extent
  // was keyed for findChildIndexCallback.
  testWidgets('a refresh that moves visible works to the head lays out', (
    tester,
  ) async {
    setViewSize(tester, const Size(400, 800));

    final before = [for (var id = 1; id <= 40; id++) id];
    var ids = before;
    late StateSetter refresh;
    await tester.pumpWidget(
      MaterialApp(
        theme: replicaTheme(Brightness.light),
        home: StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return Scaffold(
              body: CustomScrollView(
                slivers: [
                  IllustFeedGrid(
                    itemCount: ids.length,
                    itemIds: ids,
                    itemBuilder: (context, index) => SizedBox(
                      height: 60 + (ids[index] * 37 % 7) * 30,
                      child: Text('work ${ids[index]}'),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
    await tester.pump();
    refresh(() => ids = [25, 26, 27, 100, 101, ...before.take(24)]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(tester.takeException(), isNull);
  });
}
