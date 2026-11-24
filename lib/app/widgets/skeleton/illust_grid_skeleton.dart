import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/settings_controller.dart';
import '../../layout/window_layout_spec.dart';
import '../../navigation/home_shell_metrics.dart';
import '../../theme/func_semantic_tokens.dart';
import '../feed/feed_grid.dart';
import '../feed/illust_card.dart';
import 'func_skeleton.dart';

/// First-load placeholder for the illustration waterfall grid (R3). The
/// column count, card width and paddings come from the same inputs as the
/// real [IllustFeedGrid], so cards land on the same x positions when the
/// data arrives — only the vertical extents differ.
class IllustGridSkeleton extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final density = ref.watch(feedDensityProvider);
    final direction = Directionality.of(context);
    final pad = padding.resolve(direction);
    final rail = HomeShellChrome.maybeOf(context)?.railExtent ?? 0.0;
    final leftOrigin = direction == TextDirection.ltr ? rail : 0.0;
    final windowSpec = WindowLayoutSpec.of(context);
    return FuncSkeleton(
      label: label,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tokens = FuncSemanticTokens.of(context);
          Widget buildColumns({
            required int columns,
            required double columnWidth,
            required EdgeInsets resolvedPadding,
            required int columnOffset,
          }) => Padding(
            padding: resolvedPadding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var c = 0; c < columns; c++) ...[
                  if (c > 0) SizedBox(width: crossAxisSpacing),
                  Expanded(
                    child: _SkeletonColumn(
                      column: c + columnOffset,
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
          );

          final bookSplit = windowSpec.bookSplitFor(
            constraints.maxWidth,
            leftOrigin: leftOrigin,
          );
          if (bookSplit != null) {
            final seamPad = crossAxisSpacing / 2;
            final leftPad = EdgeInsets.fromLTRB(
              pad.left,
              pad.top,
              seamPad,
              pad.bottom,
            );
            final rightPad = EdgeInsets.fromLTRB(
              seamPad,
              pad.top,
              pad.right,
              pad.bottom,
            );
            final leftInner = bookSplit.leftWidth - leftPad.horizontal;
            final rightInner = bookSplit.rightWidth - rightPad.horizontal;
            final leftCols = math.max(
              1,
              illustColumnsForContext(context, leftInner, density),
            );
            final rightCols = math.max(
              1,
              illustColumnsForContext(context, rightInner, density),
            );
            return ClipRect(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: bookSplit.leftWidth,
                    child: buildColumns(
                      columns: leftCols,
                      columnWidth:
                          (leftInner - (leftCols - 1) * crossAxisSpacing) /
                          leftCols,
                      resolvedPadding: leftPad,
                      columnOffset: 0,
                    ),
                  ),
                  if (bookSplit.hingeGap > 0)
                    SizedBox(width: bookSplit.hingeGap),
                  Expanded(
                    child: buildColumns(
                      columns: rightCols,
                      columnWidth:
                          (rightInner - (rightCols - 1) * crossAxisSpacing) /
                          rightCols,
                      resolvedPadding: rightPad,
                      columnOffset: leftCols,
                    ),
                  ),
                ],
              ),
            );
          }

          final horizontal = pad.horizontal;
          final columns = illustColumnsForContext(
            context,
            constraints.maxWidth - horizontal,
            density,
          );
          final columnWidth =
              (constraints.maxWidth -
                  horizontal -
                  (columns - 1) * crossAxisSpacing) /
              columns;
          return ClipRect(
            child: buildColumns(
              columns: columns,
              columnWidth: columnWidth,
              resolvedPadding: pad,
              columnOffset: 0,
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
