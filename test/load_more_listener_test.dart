import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/feed/load_more_listener.dart';

import 'helpers/view_size.dart';

void main() {
  const rowHeight = 100.0;
  const screen = Size(400, 600);

  Future<List<int>> pumpList(
    WidgetTester tester, {
    required int rows,
    Widget? nested,
  }) async {
    setViewSize(tester, screen);
    final asks = <int>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LoadMoreListener(
          itemCount: rows,
          onLoadMore: () => asks.add(rows),
          child: ListView(
            children: [
              ?nested,
              for (var i = 0; i < rows; i++) const SizedBox(height: rowHeight),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return asks;
  }

  testWidgets('a list asks once its end is within three screens', (
    tester,
  ) async {
    // 60 rows: 6000 px, the end 9 screens below the first.
    final asks = await pumpList(tester, rows: 60);
    expect(asks, isEmpty);

    // 3500 px down the end is 2500 px away, still past 3 × 600.
    await tester.drag(find.byType(ListView), const Offset(0, -3500));
    await tester.pump();
    expect(asks, isEmpty);

    await tester.drag(find.byType(ListView), const Offset(0, -800));
    await tester.pump();
    expect(asks, isNotEmpty);
  });

  testWidgets('a nested row reaching its end asks for nothing', (tester) async {
    final asks = await pumpList(
      tester,
      rows: 60,
      nested: SizedBox(
        height: rowHeight,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [for (var i = 0; i < 3; i++) const SizedBox(width: 300)],
        ),
      ),
    );
    await tester.drag(find.byType(ListView).last, const Offset(-400, 0));
    await tester.pump();
    expect(asks, isEmpty);
  });

  testWidgets('a commit still inside the zone asks again without a scroll', (
    tester,
  ) async {
    // Short of the screen: the first layout asks.
    expect(await pumpList(tester, rows: 3), [3]);
    // A page that leaves it short changes no scroll extent; the commit
    // itself is checked after its frame.
    expect(await pumpList(tester, rows: 4), [4]);
    // Rows appended after a laid-out end are laid out; the list now scrolls.
    expect(await pumpList(tester, rows: 8), [8]);
    // A commit past the laid-out rows is not laid out at once: the list's
    // end is still the old estimate and must not ask again.
    expect(await pumpList(tester, rows: 20), [20]);
    final asks = await pumpList(tester, rows: 40);
    expect(asks, isEmpty);
    // The scroll asks, and its check stands for the pending commit: a size
    // change alone (the tail's spinner turning into an error) does not
    // retry.
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pump();
    expect(asks, isNotEmpty);
    expect(
      await pumpList(tester, rows: 40, nested: const SizedBox(height: 10)),
      isEmpty,
    );
  });
}
