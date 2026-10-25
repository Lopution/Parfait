import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:material_ui/material_ui.dart';

import 'motion_tokens.dart';

/// Moves chrome that gets out of the way while reading — the shell's bottom
/// bar, the detail page's action bar — with the vertical scroll of one
/// page, as Material 3's `exitAlways` bars do: the chrome slides as far as
/// the page scrolls, out going down and back going up, and once the scroll
/// rests, chrome left part way settles at an end.
///
/// Only the user's own scrolling counts: a drag and the fling it releases
/// into, a wheel. Programmatic scrolls (scroll-to-top, restoring a
/// position) leave the chrome alone. Only depth-0 vertical updates count,
/// so a nested horizontal strip or a carousel never moves the chrome
/// either, and overscroll (a bounce) is not reading direction.
class ScrollHideTracker {
  bool _userScroll = false;
  bool _dragged = false;
  double _lastDelta = 0;
  BuildContext? _lastScrollable;

  /// Slides [visibility] (1 shown, 0 hidden), which moves the chrome
  /// [travel] logical pixels end to end, by [notification]'s scroll.
  /// Returns where the chrome should settle once the user's scroll rests:
  /// true hidden, false shown; null otherwise.
  bool? update(
    ScrollNotification notification,
    AnimationController visibility, {
    required double travel,
  }) {
    if (notification.depth != 0) return null;
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical || !metrics.hasContentDimensions) {
      return null;
    }
    if (!identical(notification.context, _lastScrollable)) {
      _lastScrollable = notification.context;
      _userScroll = false;
    }
    switch (notification) {
      // The position reports a user direction from a drag's first move,
      // or a wheel tick, until it comes to rest — through the fling a
      // drag releases into. animateTo and jumpTo leave it idle.
      case UserScrollNotification(:final direction):
        final scrolling = direction != ScrollDirection.idle;
        if (scrolling == _userScroll) return null;
        _userScroll = scrolling;
        if (scrolling) {
          _dragged = false;
          _lastDelta = 0;
          return null;
        }
        return _settle(visibility);
      case ScrollUpdateNotification(:final scrollDelta?, :final dragDetails)
          when _userScroll && travel > 0:
        if (dragDetails != null) _dragged = true;
        final delta =
            _inRange(metrics, metrics.pixels) -
            _inRange(metrics, metrics.pixels - scrollDelta);
        if (delta == 0) return null;
        _lastDelta = delta;
        final shown = (visibility.value - delta / travel).clamp(0.0, 1.0);
        if (shown != visibility.value) visibility.value = shown;
        return null;
      default:
        return null;
    }
  }

  /// [pixels] within [metrics]' extent: the part of a scroll past an edge
  /// does not move the chrome.
  static double _inRange(ScrollMetrics metrics, double pixels) =>
      pixels.clamp(metrics.minScrollExtent, metrics.maxScrollExtent);

  /// The end chrome settles at when the user's scroll rests: the nearer
  /// one after a drag, the way it went after wheel ticks, each of which
  /// rests at once. None if it did not move, or if something else has
  /// sent it on its way since.
  bool? _settle(Animation<double> visibility) {
    if (_lastDelta == 0 || visibility.isAnimating) return null;
    return _dragged ? visibility.value < 0.5 : _lastDelta > 0;
  }
}

/// Settles chrome driven by [visibility] (1 shown, 0 hidden) at the end
/// [hidden] names, on [MotionTokens.chromeCurve], over its share of
/// [visibility]'s duration from where it is; at once under reduced
/// motion. A call that matches where it is or is already heading does
/// nothing.
void slideChrome(
  BuildContext context,
  AnimationController visibility, {
  required bool hidden,
}) {
  final target = hidden ? 0.0 : 1.0;
  if (visibility.isAnimating
      ? visibility.status.isForwardOrCompleted != hidden
      : visibility.value == target) {
    return;
  }
  if (!MotionTokens.enabled(context)) {
    visibility.value = target;
  } else if (hidden) {
    visibility.animateBack(target, curve: MotionTokens.chromeCurve);
  } else {
    visibility.animateTo(target, curve: MotionTokens.chromeCurve);
  }
}

/// Chrome at the screen bottom that [ScrollHideTracker] and [slideChrome]
/// move: it slides down by its own height and fades out at the end.
class ScrollHiddenChrome extends StatelessWidget {
  const ScrollHiddenChrome({
    super.key,
    required this.visibility,
    required this.child,
  });

  /// 1 shown, 0 hidden. The chrome moves linearly with it, so it follows
  /// a scroll pixel for pixel; [slideChrome] puts the curve on the value.
  final Animation<double> visibility;
  final Widget child;

  /// The share of the way out over which chrome fades, at the hidden end.
  /// Opaque while it moves, it never lets the page show through while a
  /// finger holds it part way; the fade takes the shadow it casts up with
  /// it once it is all but out.
  static const _fade = Interval(0, 0.25);

  /// The opacity of chrome at [visibility].
  static Animation<double> opacityOf(Animation<double> visibility) =>
      visibility.drive(CurveTween(curve: _fade));

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: opacityOf(visibility),
      child: SlideTransition(
        position: visibility.drive(
          Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero),
        ),
        child: child,
      ),
    );
  }
}
