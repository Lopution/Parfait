import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/layout/card_columns.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';

import 'helpers/view_size.dart';

/// A card 100 high that records its mounts and unmounts.
class _Card extends StatefulWidget {
  const _Card(this.index, this.log);

  final int index;
  final Map<int, (int, int)> log;

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  void _count({int mounts = 0, int unmounts = 0}) => widget.log.update(
    widget.index,
    (seen) => (seen.$1 + mounts, seen.$2 + unmounts),
    ifAbsent: () => (mounts, unmounts),
  );

  @override
  void initState() {
    super.initState();
    _count(mounts: 1);
  }

  @override
  void dispose() {
    _count(unmounts: 1);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 100);
}

void main() {
  for (final grid in [false, true]) {
    testWidgets('a ${grid ? 'grid' : 'card list'} builds the cache area of an '
        'appended page over frames and keeps the cards it built', (
      tester,
    ) async {
      setViewSize(tester, const Size(400, 800));
      final log = <int, (int, int)>{};
      final controller = ScrollController();
      addTearDown(controller.dispose);
      Future<void> show(int count) {
        Widget card(BuildContext context, int index) => _Card(index, log);
        return tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: CustomScrollView(
                controller: controller,
                scrollCacheExtent: kFeedCacheExtent,
                slivers: [
                  if (grid)
                    IllustFeedGrid(itemCount: count, itemBuilder: card)
                  else
                    SliverCardList(itemCount: count, itemBuilder: card),
                ],
              ),
            ),
          ),
        );
      }

      Set<int> mounted() => {
        for (final MapEntry(:key, value: (mounts, unmounts)) in log.entries)
          if (mounts > unmounts) key,
      };
      int furthest() => mounted().reduce((a, b) => a > b ? a : b);
      Future<void> settle() async {
        while (tester.binding.hasScheduledFrame) {
          await tester.pump();
        }
      }

      await show(24);
      await settle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await settle();
      final built = mounted();
      expect(built, contains(23));

      // A page appended at the end: the cache area past the last card
      // grows a step a frame.
      await show(200);
      final first = furthest();
      expect(first, greaterThan(23));
      await tester.pump();
      final second = furthest();
      expect(second, greaterThan(first));
      await settle();
      if (!grid) {
        // Rows of 100 under an 800 viewport with half a screen of cache:
        // a quarter screen (two rows) a frame up to four rows past the end.
        expect([first, second, furthest()], [25, 27, 27]);
      }
      // No card it had built left or mounted again.
      for (final index in built) {
        expect(log[index], (1, 0), reason: '$index');
      }

      // A jump lands with the screen built to its bottom in its first
      // frame.
      controller.jumpTo(3000);
      await tester.pump();
      expect(
        tester
            .widgetList(find.byType(_Card))
            .map((card) => tester.getBottomLeft(find.byWidget(card)).dy),
        contains(greaterThanOrEqualTo(800)),
      );
      await settle();
    });
  }
}
