import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/app/widgets/feed/feed_text_warmup.dart';

List<WarmText> _lines(int count) => [
  for (var i = 0; i < count; i++)
    (text: 'title $i', style: const TextStyle(fontSize: 14), locale: null),
];

void main() {
  testWidgets('warms one line per frame gap, and only after a short frame', (
    tester,
  ) async {
    // An indeterminate spinner keeps the next frame scheduled, as a fling
    // does.
    await tester.pumpWidget(
      const MaterialApp(home: CircularProgressIndicator()),
    );
    var now = Duration.zero;
    final warmup = FeedTextWarmup(clock: () => now);
    warmup.add(
      _lines(3),
      textScaler: TextScaler.noScaling,
      textDirection: TextDirection.ltr,
    );

    // Frame 1 starts at 0 and nothing runs inside it.
    await tester.pump(const Duration(milliseconds: 16));
    expect(warmup.pendingCount, 3);

    // Its gap opens 1 ms after it started: room for one line, not two.
    now = const Duration(milliseconds: 1);
    await tester.pump(const Duration(milliseconds: 16));
    expect(warmup.pendingCount, 2);

    // Frame 2 started at 1 ms and ran 4 ms: a slow line would overrun the
    // vsync, so this gap is skipped.
    now = const Duration(milliseconds: 5);
    await tester.pump(const Duration(milliseconds: 16));
    expect(warmup.pendingCount, 2);

    now = const Duration(milliseconds: 6);
    await tester.pump(const Duration(milliseconds: 16));
    expect(warmup.pendingCount, 1);
    // Disposing with a gap pending leaves no timer or frame callback.
    warmup.dispose();
  });

  testWidgets('with no frame on the way, drains without scheduling one', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final warmup = FeedTextWarmup();
    warmup.add(
      _lines(3),
      textScaler: TextScaler.noScaling,
      textDirection: TextDirection.ltr,
    );

    await tester.pump(Duration.zero);
    expect(warmup.pendingCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    warmup.dispose();
  });

  testWidgets('the grid queues each new item once and restarts on refresh', (
    tester,
  ) async {
    var ids = [1, 2, 3];
    final warmed = <int>[];
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: replicaTheme(Brightness.light),
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return CustomScrollView(
              slivers: [
                IllustFeedGrid(
                  itemCount: ids.length,
                  itemIds: ids,
                  warmTexts: (context, index) {
                    warmed.add(ids[index]);
                    return const [];
                  },
                  itemBuilder: (context, index) =>
                      SizedBox(height: 100, child: Text('work ${ids[index]}')),
                ),
              ],
            );
          },
        ),
      ),
    );
    expect(warmed, [1, 2, 3]);

    // The next page arrives; a rebuild without new items queues nothing.
    update(() => ids = [...ids, 4, 5]);
    await tester.pump();
    update(() {});
    await tester.pump();
    expect(warmed, [1, 2, 3, 4, 5]);

    // A refresh replaces the head: the new feed starts over.
    update(() => ids = [9, 1]);
    await tester.pump();
    expect(warmed, [1, 2, 3, 4, 5, 9, 1]);
  });
}
