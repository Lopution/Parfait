import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Builds a sliver from the width it is laid out at.
///
/// [SliverLayoutBuilder] calls its builder whenever its [SliverConstraints]
/// change, and they carry the scroll offset: a list returned from it was a
/// new list on every scroll frame, so every row on screen rebuilt — and
/// re-sent its semantics — each frame. This one calls [builder] only when
/// the cross-axis extent changes, a dependency it read changes, or its
/// parent rebuilds it.
class SliverWidthBuilder extends AbstractLayoutBuilder<double> {
  const SliverWidthBuilder({super.key, required this.builder});

  @override
  final Widget Function(BuildContext context, double crossAxisExtent) builder;

  @override
  RenderAbstractLayoutBuilderMixin<double, RenderSliver> createRenderObject(
    BuildContext context,
  ) => _RenderSliverWidthBuilder();
}

class _RenderSliverWidthBuilder extends RenderSliver
    with
        RenderObjectWithChildMixin<RenderSliver>,
        RenderObjectWithLayoutCallbackMixin,
        RenderAbstractLayoutBuilderMixin<double, RenderSliver> {
  @override
  double get layoutInfo => constraints.crossAxisExtent;

  @override
  double childMainAxisPosition(RenderObject child) => 0;

  @override
  void performLayout() {
    runLayoutCallback();
    child?.layout(constraints, parentUsesSize: true);
    geometry = child?.geometry ?? SliverGeometry.zero;
  }

  // The child sits at this sliver's origin: no transform to apply.
  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {}

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child != null && child.geometry!.visible) {
      context.paintChild(child, offset);
    }
  }

  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    final child = this.child;
    return child != null &&
        child.geometry!.hitTestExtent > 0 &&
        child.hitTest(
          result,
          mainAxisPosition: mainAxisPosition,
          crossAxisPosition: crossAxisPosition,
        );
  }
}
