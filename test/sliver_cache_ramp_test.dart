import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/layout/card_columns.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';

import 'helpers/view_size.dart';

/// A card 100 high; [index] keeps each instance distinct for finders.
class _Card extends StatelessWidget {
  const _Card(this.index);

  final int index;

  @override
  Widget build(BuildContext context) => const SizedBox(height: 100);
}

void main() {
  for (final grid in [false, true]) {
    testWidgets('a ${grid ? 'grid' : 'card list'} that jumps far fills the '
        'screen in its first frame', (tester) async {
      setViewSize(tester, const Size(400, 800));
      final controller = ScrollController();
      addTearDown(controller.dispose);
      Widget card(BuildContext context, int index) => _Card(index);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: CustomScrollView(
              controller: controller,
              scrollCacheExtent: kFeedCacheExtent,
              slivers: [
                if (grid)
                  IllustFeedGrid(itemCount: 200, itemBuilder: card)
                else
                  SliverCardList(itemCount: 200, itemBuilder: card),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The cards on screen, as (index, rect).
      Iterable<(int, Rect)> shown() => [
        for (final card in tester.widgetList<_Card>(find.byType(_Card)))
          (card.index, tester.getRect(find.byWidget(card))),
      ].where((card) => card.$2.overlaps(Offset.zero & const Size(400, 800)));
      final before = shown().map((card) => card.$1).reduce(math.max);

      // The cache area past the screen grows over frames; the screen
      // itself is built whole, past every card shown before the jump.
      controller.jumpTo(3000);
      await tester.pump();
      expect(shown().map((card) => card.$1), everyElement(greaterThan(before)));
      expect(
        shown().map((card) => card.$2.bottom),
        contains(greaterThanOrEqualTo(800)),
      );
      await tester.pumpAndSettle();
    });
  }
}
