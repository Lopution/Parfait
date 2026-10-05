import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

import '../../app/format/app_format.dart';
import '../../app/theme/func_semantic_tokens.dart';

@immutable
class ProfileStatisticData {
  const ProfileStatisticData({
    required this.id,
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  final String id;
  final IconData icon;
  final String label;
  final int value;
  final VoidCallback? onTap;
}

/// Shared stat control for the header grid cells and the about-page rows.
/// A single semantic node announces the label and value together.
class ProfileStatistic extends StatelessWidget {
  const ProfileStatistic({
    super.key,
    required this.statistic,
    this.compact = false,
  });

  final ProfileStatisticData statistic;

  /// Header grid cell: centred value-over-label, no icon. Text sits on the
  /// page surface now, so there is no `foregroundColor` override anymore.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      key: ValueKey(
        'profile-stat-${statistic.id}-${compact ? 'header' : 'about'}',
      ),
      container: true,
      button: statistic.onTap != null,
      label: '${statistic.label}, ${AppFormat.count(context, statistic.value)}',
      onTap: statistic.onTap,
      child: ExcludeSemantics(
        child: compact
            ? Material(
                type: MaterialType.transparency,
                borderRadius: FuncShape.control,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: statistic.onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FuncSpacing.xs,
                      vertical: FuncSpacing.xs,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          AppFormat.count(context, statistic.value),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: colors.onSurface,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        Text(
                          statistic.label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : ListTile(
                dense: true,
                leading: Icon(statistic.icon, size: 18),
                title: Text(statistic.label),
                trailing: Text(AppFormat.count(context, statistic.value)),
                onTap: statistic.onTap,
              ),
      ),
    );
  }
}

/// Equal-width statistics grid: picks the first column count from
/// `6 → 3 → 2 → 1` whose widest cell still fits, so labels are never
/// truncated and the row never scrolls horizontally (R3). Height comes from
/// the tallest cell in each row — the profile header measures this widget as
/// part of its content (§2), so no dry-layout support is implemented.
class ProfileStatisticsGrid extends MultiChildRenderObjectWidget {
  const ProfileStatisticsGrid({
    super.key,
    required List<ProfileStatistic> statistics,
  }) : super(children: statistics);

  /// Column counts tried in order; each divides the six profile stats into
  /// whole rows (6, 3×2, 2×3, 1×6).
  static const columnChoices = [6, 3, 2, 1];
  static const gap = FuncSpacing.sm;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderStatisticsGrid();
}

class _GridCellParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderStatisticsGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _GridCellParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _GridCellParentData> {
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _GridCellParentData) {
      child.parentData = _GridCellParentData();
    }
  }

  /// The widest cell decides the column count, so no label is ever clipped.
  int _columnCount(double maxWidth) {
    var widest = 0.0;
    var child = firstChild;
    while (child != null) {
      widest = math.max(widest, child.getMaxIntrinsicWidth(double.infinity));
      child = childAfter(child);
    }
    for (final columns in ProfileStatisticsGrid.columnChoices) {
      final cellWidth =
          (maxWidth - ProfileStatisticsGrid.gap * (columns - 1)) / columns;
      if (widest <= cellWidth) return columns;
    }
    return 1;
  }

  @override
  void performLayout() {
    final boundedWidth = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : constraints.minWidth;
    final columns = _columnCount(boundedWidth);
    final cellWidth =
        (boundedWidth - ProfileStatisticsGrid.gap * (columns - 1)) / columns;
    final cells = getChildrenAsList();
    var top = 0.0;
    var index = 0;
    while (index < cells.length) {
      final end = math.min(index + columns, cells.length);
      var rowHeight = 0.0;
      for (var i = index; i < end; i++) {
        cells[i].layout(
          BoxConstraints.tightFor(width: cellWidth),
          parentUsesSize: true,
        );
        rowHeight = math.max(rowHeight, cells[i].size.height);
      }
      var left = 0.0;
      for (var i = index; i < end; i++) {
        final parentData = cells[i].parentData! as _GridCellParentData;
        parentData.offset = Offset(left, top);
        left += cellWidth + ProfileStatisticsGrid.gap;
      }
      top += rowHeight + ProfileStatisticsGrid.gap;
      index = end;
    }
    final height = top == 0.0 ? 0.0 : top - ProfileStatisticsGrid.gap;
    size = constraints.constrain(Size(boundedWidth, height));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}
