import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'motion_tokens.dart';

/// Turns the vertical scroll of one page into hide/show calls for chrome
/// that gets out of the way while reading — the shell's bottom bar, the
/// detail page's action bar — on Shaft's rule: a frame that scrolls more
/// than [framePhysicalPixels] down hides, up shows.
///
/// Only the user's own scrolling counts: a drag and the fling it releases
/// into, a wheel. Programmatic scrolls (scroll-to-top, restoring a
/// position) leave the chrome alone. Only depth-0 vertical updates count, so a nested
/// horizontal strip or a carousel never moves the chrome either, and
/// overscroll (a bounce, a stretch) is not reading direction.
class ScrollHideTracker {
  /// Shaft's `dy > 8` per `onScrolled` call: one frame's scroll, in
  /// physical pixels.
  static const framePhysicalPixels = 8.0;

  bool _userScroll = false;
  double? _lastPixels;
  BuildContext? _lastScrollable;
  Duration? _frame;
  double _frameDelta = 0;

  /// True to hide, false to show, null to leave the chrome as it is.
  bool? update(
    ScrollNotification notification, {
    required double devicePixelRatio,
  }) {
    if (notification.depth != 0) return null;
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical || !metrics.hasContentDimensions) {
      return null;
    }
    if (!identical(notification.context, _lastScrollable)) {
      _lastScrollable = notification.context;
      _lastPixels = null;
      _userScroll = false;
    }
    final pixels = metrics.pixels.clamp(
      metrics.minScrollExtent,
      metrics.maxScrollExtent,
    );
    final last = _lastPixels;
    _lastPixels = pixels;
    switch (notification) {
      // The position reports a user direction from a drag's first move,
      // or a wheel tick, until it comes to rest — through the fling a
      // drag releases into. animateTo and jumpTo leave it idle.
      case UserScrollNotification(:final direction):
        _userScroll = direction != ScrollDirection.idle;
        _frame = null;
        return null;
      case ScrollUpdateNotification() when _userScroll && last != null:
        break;
      default:
        return null;
    }
    // Several pointer moves can land between two frames; they add up to
    // that frame's scroll.
    final frame = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    if (frame != _frame) {
      _frame = frame;
      _frameDelta = 0;
    }
    _frameDelta += pixels - last;
    if (_frameDelta.abs() * devicePixelRatio <= framePhysicalPixels) {
      return null;
    }
    return _frameDelta > 0;
  }
}

/// Moves chrome driven by [visibility] (1 shown, 0 hidden) toward
/// [hidden] on [MotionTokens.chromeScrollHide]; at once under reduced
/// motion. A call that matches where it is already heading does nothing.
void slideChrome(
  BuildContext context,
  AnimationController visibility, {
  required bool hidden,
}) {
  if (visibility.status.isForwardOrCompleted != hidden) return;
  if (!MotionTokens.enabled(context)) {
    visibility.value = hidden ? 0 : 1;
  } else if (hidden) {
    visibility.reverse();
  } else {
    visibility.forward();
  }
}

/// Chrome at the screen bottom that [slideChrome] hides: it slides down by
/// its own height and fades out together, on
/// [MotionTokens.chromeScrollCurve].
class ScrollHiddenChrome extends StatelessWidget {
  const ScrollHiddenChrome({
    super.key,
    required this.visibility,
    required this.child,
  });

  /// 1 shown, 0 hidden; linear — the curve is applied here.
  final Animation<double> visibility;
  final Widget child;

  /// How much of the chrome shows at [visibility]'s current value.
  static double shownOf(Animation<double> visibility) =>
      MotionTokens.chromeScrollCurve.transform(visibility.value);

  @override
  Widget build(BuildContext context) {
    final shown = visibility.drive(
      CurveTween(curve: MotionTokens.chromeScrollCurve),
    );
    return FadeTransition(
      opacity: shown,
      child: SlideTransition(
        position: shown.drive(
          Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero),
        ),
        child: child,
      ),
    );
  }
}
