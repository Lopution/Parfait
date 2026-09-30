import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../theme/func_semantic_tokens.dart';
import '../feed/feed_grid.dart';
import '../feed/illust_card.dart';
import 'func_skeleton.dart';

/// First-load placeholder for the illustration waterfall grid (R3). The
/// column count, card width and paddings come from the same inputs as the
/// real [IllustFeedGrid], so cards land on the same x positions when the
/// data arrives — only the vertical extents differ.
class IllustGridSkeleton extends StatelessWidget {
  const IllustGridSkeleton({
    super.key,
    required this.label,
    this.padding = IllustFeedGrid.defaultPadding,
    this.mainAxisSpacing = IllustFeedGrid.defaultMainAxisSpacing,
    this.crossAxisSpacing = IllustFeedGrid.defaultCrossAxisSpacing,
  });

  final String label;

  /// Same contract as `IllustFeedGrid.padding`: callers pass the values of
  /// the grid they stand in for.
  final EdgeInsetsGeometry padding;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  /// Portrait image ratios cycled through each column, offset per column
  /// so adjacent cards do not align — the pattern reads as a waterfall.
  static const _imageRatios = [1.33, 1.0, 0.75, 1.5, 1.2];

  @override
  Widget build(BuildContext context) {
    return FuncSkeleton(
      label: label,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontal = padding.horizontal;
          final columns = illustColumnsFor(constraints.maxWidth - horizontal);
          final columnWidth =
              (constraints.maxWidth -
                  horizontal -
                  (columns - 1) * crossAxisSpacing) /
              columns;
          final tokens = FuncSemanticTokens.of(context);
          return ClipRect(
            child: Padding(
              padding: padding,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var c = 0; c < columns; c++) ...[
                    if (c > 0) SizedBox(width: crossAxisSpacing),
                    Expanded(
                      child: _SkeletonColumn(
                        column: c,
                        columnWidth: columnWidth,
                        maxHeight: constraints.maxHeight,
                        mainAxisSpacing: mainAxisSpacing,
                        titleStyle: tokens.label,
                        authorStyle: tokens.caption,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One waterfall column of skeleton cards. Cards keep stacking until the
/// column exceeds [maxHeight]; an unbounded height means three cards.
class _SkeletonColumn extends StatelessWidget {
  const _SkeletonColumn({
    required this.column,
    required this.columnWidth,
    required this.maxHeight,
    required this.mainAxisSpacing,
    required this.titleStyle,
    required this.authorStyle,
  });

  final int column;
  final double columnWidth;
  final double maxHeight;
  final double mainAxisSpacing;
  final TextStyle titleStyle;
  final TextStyle authorStyle;

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[];
    var height = 0.0;
    var index = 0;
    while (true) {
      final ratio =
          IllustGridSkeleton._imageRatios[(index + column) %
              IllustGridSkeleton._imageRatios.length];
      final cardHeight = _cardHeight(
        columnWidth: columnWidth,
        ratio: ratio,
        titleStyle: titleStyle,
        authorStyle: authorStyle,
      );
      if (cards.isNotEmpty) height += mainAxisSpacing;
      height += cardHeight;
      cards.add(
        _SkeletonCard(
          columnWidth: columnWidth,
          imageHeight: columnWidth * ratio,
          titleStyle: titleStyle,
          authorStyle: authorStyle,
        ),
      );
      index++;
      if (maxHeight.isFinite ? height > maxHeight : index >= 3) break;
    }
    // The column claims exactly the visible height and lets the last card
    // overflow past it: OverflowBox lays the children out at their real
    // size, ClipRect cuts the excess — no scroll, no overflow error.
    return SizedBox(
      height: maxHeight.isFinite ? math.min(height, maxHeight) : height,
      child: ClipRect(
        child: OverflowBox(
          maxHeight: double.infinity,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) SizedBox(height: mainAxisSpacing),
                cards[i],
              ],
            ],
          ),
        ),
      ),
    );
  }

  static double _cardHeight({
    required double ratio,
    required TextStyle titleStyle,
    required TextStyle authorStyle,
    required double columnWidth,
  }) {
    return columnWidth * ratio +
        FuncSpacing.xs +
        _lineHeight(titleStyle) +
        FuncSpacing.xxs +
        _lineHeight(authorStyle);
  }

  static double _lineHeight(TextStyle style) =>
      (style.fontSize ?? 14) * (style.height ?? 1.2);
}

/// One skeleton card: image bone at [FuncShape.card], then the 10px-indented
/// title/author line pair matching `illust_card.dart`'s text block. The
/// bookmark button is not painted.
class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard({
    required this.columnWidth,
    required this.imageHeight,
    required this.titleStyle,
    required this.authorStyle,
  });

  final double columnWidth;
  final double imageHeight;
  final TextStyle titleStyle;
  final TextStyle authorStyle;

  @override
  Widget build(BuildContext context) {
    final textWidth = math.max(0.0, columnWidth - IllustCard.textIndent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonBone(
          width: columnWidth,
          height: imageHeight,
          borderRadius: FuncShape.card,
        ),
        const SizedBox(height: FuncSpacing.xs),
        Padding(
          padding: const EdgeInsets.only(left: IllustCard.textIndent),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBone.text(width: textWidth * 0.7, style: titleStyle),
              const SizedBox(height: FuncSpacing.xxs),
              SkeletonBone.text(width: textWidth * 0.4, style: authorStyle),
            ],
          ),
        ),
      ],
    );
  }
}
