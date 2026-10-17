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

/// Longest a transition holds semantics back: past it they flow again, so
/// a transition that never ends cannot leave the platform behind.
const kSemanticsHoldLimit = Duration(seconds: 2);

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
///
/// Route transitions and branch switches hold pushes back ([holdSemantics]):
/// a page entering or returning re-sent its whole tree mid-animation, up to
/// 11.6 ms in one frame. The tree goes out one interval after the last
/// transition ends, on a still frame.
final class AppRootPipelineOwner extends PipelineOwner {
  AppRootPipelineOwner() : super(onSemanticsUpdate: _noRootSemantics);

  // The root owner has no root node, so it never produces semantics.
  static void _noRootSemantics(SemanticsUpdate _) {}

  /// Holds semantics pushes until the returned release runs; releasing
  /// twice is harmless. Without this owner (tests) or with semantics off
  /// nothing is held, and the release asks for no frame.
  static VoidCallback holdSemantics() {
    final owner = RendererBinding.instance.rootPipelineOwner;
    return owner is AppRootPipelineOwner && owner.semanticsOwner != null
        ? owner._hold()
        : _noRelease;
  }

  static void _noRelease() {}

  Duration? _lastPush;
  Timer? _pendingPush;

  int _holds = 0;
  bool _holdExpired = false;
  Timer? _holdLimit;

  /// The interval after the last hold, before the held tree goes out.
  bool _settling = false;

  bool get _held => (_holds > 0 && !_holdExpired) || _settling;

  VoidCallback _hold() {
    if (_holds++ == 0) {
      _holdLimit = Timer(kSemanticsHoldLimit, () {
        _holdExpired = true;
        SchedulerBinding.instance.ensureVisualUpdate();
      });
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (--_holds == 0) _settle();
    };
  }

  void _settle() {
    _holdLimit?.cancel();
    _holdLimit = null;
    _holdExpired = false;
    _settling = true;
    _pendingPush?.cancel();
    _pendingPush = Timer(kSemanticsPushInterval, () {
      _pendingPush = null;
      _settling = false;
      SchedulerBinding.instance.ensureVisualUpdate();
    });
  }

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
    // Held: the release asks for the frame that pushes.
    if (_held) return;
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
