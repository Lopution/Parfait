import 'dart:async';
import 'dart:ui' show SemanticsUpdate;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../debug/frame_probe.dart';

/// Shortest gap between two semantics pushes to the platform. Android
/// throttles a native view's content-change and scroll accessibility events
/// to the same interval
/// (`ViewConfiguration.getSendRecurringAccessibilityEventsInterval()`).
const kSemanticsPushInterval = Duration(milliseconds: 100);

/// The app's root pipeline owner: pushes semantics at most once per
/// [kSemanticsPushInterval] and times its flushes for [FrameProbe].
///
/// Flutter pushes every changed semantics node to Android in each frame it
/// draws, and the embedding answers each push with a subtree
/// content-changed and a scroll event. With an accessibility service on (the
/// user runs one permanently) a scrolling feed spent about 2 ms of every
/// frame there. Native views are read on demand and their events are
/// throttled, so this owner keeps the platform at most one interval behind:
/// a frame within the interval of the last push skips the flush, which
/// keeps every dirty node for the next one, and a timer asks for a frame
/// when the interval ends so the last change always arrives.
final class AppRootPipelineOwner extends PipelineOwner {
  AppRootPipelineOwner() : super(onSemanticsUpdate: _noRootSemantics);

  // The root owner has no root node, so it never produces semantics.
  static void _noRootSemantics(SemanticsUpdate _) {}

  Duration? _lastPush;
  Timer? _pendingPush;

  @override
  void flushLayout() =>
      FrameProbe.instance.timePhase(UiPhase.layout, () => super.flushLayout());

  @override
  void flushCompositingBits() => FrameProbe.instance.timePhase(
    UiPhase.paint,
    () => super.flushCompositingBits(),
  );

  @override
  void flushPaint() =>
      FrameProbe.instance.timePhase(UiPhase.paint, () => super.flushPaint());

  @override
  void flushSemantics() =>
      FrameProbe.instance.timePhase(UiPhase.semantics, _flushThrottled);

  void _flushThrottled() {
    // Semantics off: nothing to push and nothing to schedule.
    if (semanticsOwner == null) return super.flushSemantics();
    final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    final sinceLast = _lastPush == null ? null : now - _lastPush!;
    // A clock that went back (a test binding restarts its fake clock per
    // test) counts as a long gap.
    if (sinceLast != null &&
        !sinceLast.isNegative &&
        sinceLast < kSemanticsPushInterval) {
      _pendingPush ??= Timer(kSemanticsPushInterval - sinceLast, () {
        _pendingPush = null;
        SchedulerBinding.instance.ensureVisualUpdate();
      });
      return;
    }
    _pendingPush?.cancel();
    _pendingPush = null;
    _lastPush = now;
    super.flushSemantics();
  }
}
