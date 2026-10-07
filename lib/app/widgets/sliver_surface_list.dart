import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A lazily built list whose rows sit on rounded surfaces by group:
/// consecutive rows with the same [groups] entry share one [color]
/// rectangle with [borderRadius] corners, and their content (ink
/// included) is clipped to it.
///
/// The surfaces are worked out from the rows' current layout every paint,
/// so rows growing in, folding away or leaving move a group's outline with
/// them — no frame shows a corner that waits for an animation to end, and
/// no row picks its corners by position. Rows never change parent when a
/// group grows or shrinks, so they keep their state and ink.
///
/// Each group's first row starts with [leadingGap] of its own top padding,
/// the space above the group, which the surface leaves out. Vertical,
/// top-to-bottom scrolling only.
class SliverSurfaceList extends SliverList {
  SliverSurfaceList.builder({
    super.key,
    required this.groups,
    required this.color,
    required this.borderRadius,
    this.leadingGap = 0,
    required NullableIndexedWidgetBuilder itemBuilder,
    ChildIndexGetter? findChildIndexCallback,
  }) : super(
         delegate: SliverChildBuilderDelegate(
           itemBuilder,
           findChildIndexCallback: findChildIndexCallback,
           childCount: groups.length,
         ),
       );

  /// The group of each row, by index; one entry per row.
  final List<Object> groups;
  final Color color;
  final BorderRadius borderRadius;
  final double leadingGap;

  @override
  RenderSliverSurfaceList createRenderObject(BuildContext context) =>
      RenderSliverSurfaceList(
        childManager: context as SliverMultiBoxAdaptorElement,
        groups: groups,
        color: color,
        borderRadius: borderRadius,
        leadingGap: leadingGap,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSliverSurfaceList renderObject,
  ) {
    renderObject
      ..groups = groups
      ..color = color
      ..borderRadius = borderRadius
      ..leadingGap = leadingGap;
  }
}

class RenderSliverSurfaceList extends RenderSliverList {
  RenderSliverSurfaceList({
    required super.childManager,
    required List<Object> groups,
    required Color color,
    required BorderRadius borderRadius,
    required double leadingGap,
  }) : _groups = groups,
       _color = color,
       _borderRadius = borderRadius,
       _leadingGap = leadingGap;

  List<Object> get groups => _groups;
  List<Object> _groups;
  set groups(List<Object> value) {
    if (identical(value, _groups)) return;
    _groups = value;
    markNeedsPaint();
  }

  Color get color => _color;
  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  BorderRadius get borderRadius => _borderRadius;
  BorderRadius _borderRadius;
  set borderRadius(BorderRadius value) {
    if (value == _borderRadius) return;
    _borderRadius = value;
    markNeedsPaint();
  }

  double get leadingGap => _leadingGap;
  double _leadingGap;
  set leadingGap(double value) {
    if (value == _leadingGap) return;
    _leadingGap = value;
    markNeedsPaint();
  }

  final List<LayerHandle<ClipRRectLayer>> _clipLayers = [];

  /// The surfaces of the groups with a row built, relative to the sliver's
  /// paint offset, top to bottom.
  List<RRect> get surfaces => [
    for (final (first, last) in _groupSpans()) _surface(first, last),
  ];

  @override
  void performLayout() {
    assert(
      constraints.axisDirection == AxisDirection.down &&
          constraints.growthDirection == GrowthDirection.forward,
      'SliverSurfaceList only supports top-to-bottom vertical scrolling.',
    );
    super.performLayout();
  }

  /// The built rows of each group, as (first, last).
  Iterable<(RenderBox, RenderBox)> _groupSpans() sync* {
    var first = firstChild;
    while (first != null) {
      final group = _groups[indexOf(first)];
      var last = first;
      for (
        var next = childAfter(last);
        next != null && _groups[indexOf(next)] == group;
        next = childAfter(next)
      ) {
        last = next;
      }
      yield (first, last);
      first = childAfter(last);
    }
  }

  RRect _surface(RenderBox first, RenderBox last) {
    final firstIndex = indexOf(first);
    final lastIndex = indexOf(last);
    final group = _groups[firstIndex];
    // Rows of the group that are not built lie beyond the cache extent, off
    // screen: running the edge past the corner radius keeps those corners
    // off screen too.
    final overhang = math.max(
      _borderRadius.topLeft.y,
      _borderRadius.bottomLeft.y,
    );
    var top = childMainAxisPosition(first);
    top = firstIndex > 0 && _groups[firstIndex - 1] == group
        ? top - overhang
        : top + _leadingGap;
    var bottom = childMainAxisPosition(last) + paintExtentOf(last);
    if (lastIndex + 1 < _groups.length && _groups[lastIndex + 1] == group) {
      bottom += overhang;
    }
    return _borderRadius.toRRect(
      Rect.fromLTRB(0, top, constraints.crossAxisExtent, bottom),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    var used = 0;
    for (final (first, last) in _groupSpans()) {
      final surface = _surface(first, last);
      // A group whose first row is collapsing past its gap has no surface
      // left; one outside the paint extent draws nothing.
      if (surface.height <= 0 ||
          surface.bottom <= 0 ||
          surface.top >= constraints.remainingPaintExtent) {
        continue;
      }
      context.canvas.drawRRect(surface.shift(offset), Paint()..color = _color);
      if (_clipLayers.length == used) {
        _clipLayers.add(LayerHandle<ClipRRectLayer>());
      }
      final handle = _clipLayers[used++];
      handle.layer = context.pushClipRRect(
        needsCompositing,
        offset,
        surface.outerRect,
        surface,
        (context, offset) => _paintRows(context, offset, first, last),
        oldLayer: handle.layer,
      );
    }
    for (final handle in _clipLayers.skip(used)) {
      handle.layer = null;
    }
    _clipLayers.length = used;
  }

  void _paintRows(
    PaintingContext context,
    Offset offset,
    RenderBox first,
    RenderBox last,
  ) {
    for (RenderBox? row = first; row != null; row = childAfter(row)) {
      final position = childMainAxisPosition(row);
      if (position < constraints.remainingPaintExtent &&
          position + paintExtentOf(row) > 0) {
        context.paintChild(row, offset + Offset(0, position));
      }
      if (row == last) break;
    }
  }

  @override
  void dispose() {
    for (final handle in _clipLayers) {
      handle.layer = null;
    }
    _clipLayers.clear();
    super.dispose();
  }
}
