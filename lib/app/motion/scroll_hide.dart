import 'package:material_ui/material_ui.dart';

import 'motion_tokens.dart';

/// Turns the vertical scroll of one page into hide/show calls for chrome
/// that gets out of the way while reading — the shell's bottom bar, the
/// detail page's action bar. A run of scrolling past the touch slop
/// downward hides, upward shows; a run resets when the direction flips or
/// another scrollable starts reporting.
///
/// Only depth-0 vertical updates count, so a nested horizontal strip or a
/// carousel never moves the chrome.
class ScrollHideTracker {
  double _run = 0;
  double? _lastPixels;
  BuildContext? _lastScrollable;

  /// True to hide, false to show, null to leave the chrome as it is.
  bool? update(ScrollNotification notification, {required double slop}) {
    if (notification.depth != 0) return null;
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical || !metrics.hasContentDimensions) {
      return null;
    }
    if (!identical(notification.context, _lastScrollable)) {
      _lastScrollable = notification.context;
      _lastPixels = null;
      _run = 0;
    }
    // Overscroll (a bounce, a stretch) is not reading direction.
    final pixels = metrics.pixels.clamp(
      metrics.minScrollExtent,
      metrics.maxScrollExtent,
    );
    final last = _lastPixels;
    _lastPixels = pixels;
    if (notification is! ScrollUpdateNotification || last == null) return null;
    final delta = pixels - last;
    if (delta == 0) return null;
    _run = _run * delta < 0 ? delta : _run + delta;
    if (_run.abs() <= slop) return null;
    final hide = _run > 0;
    _run = 0;
    return hide;
  }
}

/// Slides chrome driven by [visibility] (1 shown, 0 hidden) toward
/// [hidden], on the controller's own show/hide durations; at once under
/// reduced motion. A call that matches where it is already heading does
/// nothing.
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
