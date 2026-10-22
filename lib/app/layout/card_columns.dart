import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../motion/motion_tokens.dart';
import '../widgets/feed/feed_text_warmup.dart';
import 'sliver_width_builder.dart';

/// Card lists (novels, users, series episodes) put their cards side by side
/// on wide surfaces instead of stretching one row across the window: a
/// column per [minColumnWidth], at most [maxColumns].
abstract final class CardColumns {
  /// Narrowest a card column gets before the list drops to fewer columns.
  static const double minColumnWidth = 400;

  static const int maxColumns = 3;

  /// Columns for a list [width] wide.
  static int of(double width) =>
      (width / minColumnWidth).floor().clamp(1, maxColumns);

  /// Rows needed for [count] cards in [columns] columns.
  static int rowCount(int count, int columns) =>
      (count + columns - 1) ~/ columns;
}

/// Row [row] of a [columns]-wide card list: the cards side by side, top
/// aligned; a short last row keeps its cards at column width. Each row is
/// a [TickerPartition].
class CardRow extends StatelessWidget {
  const CardRow({
    super.key,
    required this.row,
    required this.columns,
    required this.count,
    required this.itemBuilder,
  });

  final int row;
  final int columns;
  final int count;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return TickerPartition(
      child: columns == 1
          ? itemBuilder(context, row)
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var column = 0; column < columns; column++)
                  Expanded(
                    child: row * columns + column < count
                        ? itemBuilder(context, row * columns + column)
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
    );
  }
}

/// A sliver list of [itemCount] cards laid out in [CardColumns] by the
/// sliver's own width.
class SliverCardList extends StatefulWidget {
  const SliverCardList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.warmTexts,
    this.firstId,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// The text lines of the card at an index, as the card lays them out
  /// (`NovelEntry.warmTexts`). The lines of the cards just past the built
  /// ones are laid out between frames before those cards are built
  /// ([FeedTextWindow]).
  final WarmTexts? warmTexts;

  /// The first card's id, for [warmTexts]: a different one is a refreshed
  /// feed, whose lines are laid out from the start again.
  final Object? firstId;

  @override
  State<SliverCardList> createState() => _SliverCardListState();
}

class _SliverCardListState extends State<SliverCardList> {
  final _warmup = FeedTextWindow();

  @override
  void dispose() {
    _warmup.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final warmTexts = widget.warmTexts;
    if (warmTexts != null) {
      _warmup.update(
        context,
        count: widget.itemCount,
        head: widget.firstId,
        texts: warmTexts,
      );
    }
    return SliverWidthBuilder(
      builder: (context, width) {
        final columns = CardColumns.of(width);
        return SliverList.builder(
          itemCount: CardColumns.rowCount(widget.itemCount, columns),
          itemBuilder: (context, row) {
            if (warmTexts != null) {
              final last = math.min((row + 1) * columns, widget.itemCount) - 1;
              _warmup.built(context, last);
            }
            return CardRow(
              row: row,
              columns: columns,
              count: widget.itemCount,
              itemBuilder: widget.itemBuilder,
            );
          },
        );
      },
    );
  }
}
