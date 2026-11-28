import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/layout/card_columns.dart';
import 'package:parfait/app/layout/sliver_width_builder.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/app/widgets/skeleton/illust_grid_skeleton.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'helpers/view_size.dart';

void main() {
  test('illustColumnsFor derives columns from the extent and density', () {
    // Widths from the acceptance matrix: 320/390/600/840/1200 + landscape,
    // less the grid's padding on a phone and a tablet; degenerate extents
    // keep each density's fewest.
    const columns = {
      FeedDensity.compact: [3, 3, 5, 7, 10, 13, 8, 3, 3],
      FeedDensity.standard: [2, 2, 3, 4, 6, 8, 5, 2, 2],
      FeedDensity.comfortable: [1, 1, 1, 2, 3, 4, 2, 1, 1],
    };
    const extents = <double>[320, 374, 600, 840, 1200, 1600, 984, 0, -50];
    for (final MapEntry(key: density, value: expected) in columns.entries) {
      expect(
        [for (final extent in extents) illustColumnsFor(extent, density)],
        expected,
        reason: density.name,
      );
    }
  });

  test('card lists take a column per 400dp, at most three', () {
    expect(CardColumns.of(390), 1);
    expect(CardColumns.of(815), 2);
    expect(CardColumns.of(1199), 2);
    expect(CardColumns.of(1359), 3);
    expect(CardColumns.of(2400), 3);
    expect(CardColumns.rowCount(5, 2), 3);
  });

  testWidgets('a width-built sliver takes taps after a scroll and follows a '
      'width change', (tester) async {
    setViewSize(tester, const Size(400, 600));
    final widths = <double>[];
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            SliverWidthBuilder(
              builder: (context, width) {
                widths.add(width);
                return SliverList.builder(
                  itemCount: 30,
                  itemBuilder: (context, index) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                    child: SizedBox(key: ValueKey(index), height: 100),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey(6)));
    expect(taps, 1);

    setViewSize(tester, const Size(500, 600));
    await tester.pump();
    expect(widths.last, 500);
  });

  testWidgets(
    'IllustFeedGrid counts columns on the sliver extent, not the window',
    (tester) async {
      setViewSize(tester, const Size(800, 600));
      const columns = {
        FeedDensity.standard: 2,
        FeedDensity.compact: 3,
        FeedDensity.comfortable: 1,
      };
      for (final MapEntry(key: density, value: expected) in columns.entries) {
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey(density),
            overrides: [feedDensityProvider.overrideWithValue(density)],
            child: MaterialApp(
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
          ),
        );
        await tester.pump();

        final grid = tester.widget<SliverMasonryGrid>(
          find.byType(SliverMasonryGrid),
        );
        final delegate =
            grid.gridDelegate
                as SliverSimpleGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, expected, reason: density.name);
      }
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
      ProviderScope(
        child: MaterialApp(
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
      ),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
    await tester.pump();
    refresh(() => ids = [25, 26, 27, 100, 101, ...before.take(24)]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scrolled IllustFeedGrid survives cross-column resizes and taps without blanking',
    (tester) async {
      setViewSize(tester, const Size(1100, 800));
      final ids = [for (var i = 1; i <= 80; i++) i];
      var tapped = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: replicaTheme(Brightness.light),
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  IllustFeedGrid(
                    itemCount: ids.length,
                    itemIds: ids,
                    itemBuilder: (context, index) => GestureDetector(
                      onTap: () => tapped++,
                      child: SizedBox(
                        height: 90 + (ids[index] * 41 % 6) * 35,
                        child: Text('item ${ids[index]}'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1800));
      await tester.pump();

      for (final width in const [850.0, 620.0, 1250.0, 500.0, 1050.0]) {
        setViewSize(tester, Size(width, 800));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.takeException(), isNull, reason: 'width $width');
        final visible = find.byType(GestureDetector).hitTestable();
        expect(visible, findsWidgets, reason: 'visible items at $width');
        await tester.tap(visible.first);
        await tester.pump();
      }
      expect(tapped, 5);
    },
  );

  testWidgets(
    'FoldPosture.book splits IllustFeedGrid, IllustGridSkeleton, and SliverCardList around hingeBounds',
    (tester) async {
      for (final (width, hinge) in [
        (760.0, const Rect.fromLTWH(372, 0, 16, 700)),
        (800.0, const Rect.fromLTWH(392, 0, 16, 700)),
      ]) {
        final data = MediaQueryData(
          size: Size(width, 700),
          displayFeatures: [
            ui.DisplayFeature(
              bounds: hinge,
              type: ui.DisplayFeatureType.hinge,
              state: ui.DisplayFeatureState.postureHalfOpened,
            ),
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: replicaTheme(Brightness.light),
              home: MediaQuery(
                data: data,
                child: Scaffold(
                  body: CustomScrollView(
                    slivers: [
                      IllustFeedGrid(
                        itemCount: 8,
                        itemIds: const [1, 2, 3, 4, 5, 6, 7, 8],
                        itemBuilder: (_, i) =>
                            SizedBox(key: ValueKey('grid-$i'), height: 80),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        for (var i = 0; i < 8; i++) {
          final rect = tester.getRect(find.byKey(ValueKey('grid-$i')));
          expect(
            rect.right <= hinge.left + 0.01 || rect.left >= hinge.right - 0.01,
            isTrue,
            reason: 'grid-$i $rect crossed hinge $hinge at width $width',
          );
        }

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: replicaTheme(Brightness.light),
              home: MediaQuery(
                data: data,
                child: Scaffold(
                  body: CustomScrollView(
                    slivers: [
                      SliverCardList(
                        itemCount: 4,
                        itemBuilder: (_, i) =>
                            SizedBox(key: ValueKey('row-$i'), height: 64),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        for (var i = 0; i < 4; i++) {
          final rect = tester.getRect(find.byKey(ValueKey('row-$i')));
          expect(
            rect.right <= hinge.left + 0.01 || rect.left >= hinge.right - 0.01,
            isTrue,
            reason: 'row-$i $rect crossed hinge $hinge at width $width',
          );
        }

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: replicaTheme(Brightness.light),
              home: MediaQuery(
                data: data,
                child: const Scaffold(
                  body: IllustGridSkeleton(label: 'loading'),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    },
  );
}
