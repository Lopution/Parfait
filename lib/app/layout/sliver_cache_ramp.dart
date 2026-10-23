import 'dart:math' as math;

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Builds the cache area of [sliver] past what it has built a step a frame:
/// the visible part always in full, then at most [RenderSliverCacheRamp.step]
/// of the viewport more per frame until the scroll view's cache extent is
/// reached.
///
/// Data landing on a feed or a page appended to it built the visible rows
/// and half a screen of cache in one frame (13.7–16.8 ms of layout on
/// device). The ramp never shrinks the area below the end of what is
/// built, so the list does not drop built children, and leaves the
/// leading cache to the scroll view.
class SliverCacheRamp extends SingleChildRenderObjectWidget {
  const SliverCacheRamp({super.key, required Widget sliver})
    : super(child: sliver);

  @override
  RenderSliverCacheRamp createRenderObject(BuildContext context) =>
      RenderSliverCacheRamp();
}

class RenderSliverCacheRamp extends RenderProxySliver {
  /// The part of the viewport the cache area grows by each frame.
  static const step = 0.25;

  /// Where the children built at the last layout end, in this sliver's
  /// scroll offsets.
  double? _builtEnd;
  bool _growing = false;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      geometry = SliverGeometry.zero;
      return;
    }
    final constraints = this.constraints;
    final cacheStart = constraints.scrollOffset + constraints.cacheOrigin;
    final visibleEnd =
        constraints.scrollOffset + constraints.remainingPaintExtent;
    final reach =
        math.max(_builtEnd ?? visibleEnd, visibleEnd) +
        constraints.viewportMainAxisExtent * step;
    final cache = math.min(
      constraints.remainingCacheExtent,
      reach - cacheStart,
    );
    child.layout(
      constraints.copyWith(remainingCacheExtent: cache),
      parentUsesSize: true,
    );
    final built = geometry = child.geometry!;
    if (built.scrollOffsetCorrection != null) return;
    _builtEnd = cacheStart + built.cacheExtent;
    // Held back and filled up to the hold: more is left to build.
    if (cache < constraints.remainingCacheExtent &&
        built.cacheExtent >= cache - precisionErrorTolerance) {
      _growNextFrame();
    }
  }

  void _growNextFrame() {
    if (_growing) return;
    _growing = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _growing = false;
      if (attached) markNeedsLayout();
    }, debugLabel: 'SliverCacheRamp');
  }
}
