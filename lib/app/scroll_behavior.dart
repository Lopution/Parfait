import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// App-wide scroll behavior: on desktop the mouse and trackpad drag like
/// touch (Flutter's default excludes them, leaving wheel-only scrolling).
/// Wheel smoothing itself is per-scrollable — see `SmoothWheelScroll`.
///
/// Touch physics follow the EasyRefresh convention app-wide: feed pages get
/// their feel from `_ERScrollPhysics` (a `BouncingScrollPhysics` with an
/// always-scrollable parent and no platform overscroll glow, a fling
/// stopping at the ends), and before this every other page ran platform
/// `ClampingScrollPhysics` instead — one app, two physics stacks. Mirroring
/// the same feel here ([FuncScrollPhysics]) keeps detail/settings/search
/// pages, profile NestedScrollView outer scrolls and feed scrolls on a
/// single scheme.
class FuncScrollBehavior extends MaterialScrollBehavior {
  const FuncScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const FuncScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

/// [BouncingScrollPhysics] whose fling stops at either end, the way the
/// feed's EasyRefresh footer does with `hitOver` off: a fling into the end
/// of a page that is loading more no longer overshoots and springs back
/// against the content arriving. A drag still pulls past the ends and
/// springs back on release.
class FuncScrollPhysics extends BouncingScrollPhysics {
  const FuncScrollPhysics({super.parent});

  @override
  FuncScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      FuncScrollPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final simulation = super.createBallisticSimulation(position, velocity);
    // Out of range a drag left the page pulled past an end: spring back.
    if (simulation == null || position.outOfRange) return simulation;
    return _EdgeStopSimulation(
      simulation,
      min: position.minScrollExtent,
      max: position.maxScrollExtent,
    );
  }
}

/// Runs [_inner] until it would leave [min]..[max], then rests at the edge.
class _EdgeStopSimulation extends Simulation {
  _EdgeStopSimulation(this._inner, {required this.min, required this.max})
    : super(tolerance: _inner.tolerance);

  final Simulation _inner;
  final double min;
  final double max;

  bool _past(double time) {
    final x = _inner.x(time);
    return x < min || x > max;
  }

  @override
  double x(double time) => clampDouble(_inner.x(time), min, max);

  @override
  double dx(double time) => _past(time) ? 0 : _inner.dx(time);

  @override
  bool isDone(double time) => _past(time) || _inner.isDone(time);
}
