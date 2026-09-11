import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

/// Minimum card width used to derive the masonry column count.
const _kMinCardExtent = 180.0;

/// Column count for a masonry grid with the given cross-axis extent.
/// Phone widths stay at 2 columns (beta56 behaviour); wide and foldable
/// layouts add columns naturally. Never below 2.
int illustColumnsFor(double crossAxisExtent) {
  if (crossAxisExtent <= 0) return 2;
  return math.max(2, (crossAxisExtent / _kMinCardExtent).floor());
}

/// Shared masonry sliver used by every feed (recommended, ranking, new,
/// search, history, profile, related). Column count derives from the actual
/// cross-axis extent the sliver receives — under the wide NavigationRail the
/// content width is smaller than the window, so reading `MediaQuery` here
/// would over-count columns.
class IllustFeedGrid extends StatelessWidget {
  const IllustFeedGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
    this.mainAxisSpacing = 5,
    this.crossAxisSpacing = 10,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry padding;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  @override
  Widget build(BuildContext context) {
    final horizontal = padding.resolve(Directionality.of(context)).horizontal;
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final columns = illustColumnsFor(
          constraints.crossAxisExtent - horizontal,
        );
        return SliverPadding(
          padding: padding,
          sliver: SliverMasonryGrid.count(
            crossAxisCount: columns,
            mainAxisSpacing: mainAxisSpacing,
            crossAxisSpacing: crossAxisSpacing,
            itemBuilder: itemBuilder,
            childCount: itemCount,
          ),
        );
      },
    );
  }
}
