import 'package:flutter/widgets.dart';

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
/// aligned; a short last row keeps its cards at column width.
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
    if (columns == 1) return itemBuilder(context, row);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var column = 0; column < columns; column++)
          Expanded(
            child: row * columns + column < count
                ? itemBuilder(context, row * columns + column)
                : const SizedBox.shrink(),
          ),
      ],
    );
  }
}

/// A sliver list of [itemCount] cards laid out in [CardColumns] by the
/// sliver's own width.
class SliverCardList extends StatelessWidget {
  const SliverCardList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final columns = CardColumns.of(constraints.crossAxisExtent);
        return SliverList.builder(
          itemCount: CardColumns.rowCount(itemCount, columns),
          itemBuilder: (context, row) => CardRow(
            row: row,
            columns: columns,
            count: itemCount,
            itemBuilder: itemBuilder,
          ),
        );
      },
    );
  }
}
