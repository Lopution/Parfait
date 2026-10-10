import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';

import '../haptics/app_haptics.dart';
import 'motion_tokens.dart';

/// A vertical pull-to-dismiss surface used by full-screen artwork surfaces.
/// The child keeps its own horizontal and zoom gestures; this wrapper only
/// tracks a downward drag while [enabled] is true.
class DragToDismiss extends StatefulWidget {
  const DragToDismiss({
    super.key,
    required this.child,
    required this.onDismissed,
    this.enabled = true,
    this.allowPointer,
    this.dismissDistance = 160,
    this.dismissVelocity = 1000,
  });

  final Widget child;
  final VoidCallback onDismissed;
  final bool enabled;

  /// Whether a pointer that just went down may start a dismiss drag. A
  /// control that owns every direction of its drag (a slider) rejects its
  /// pointers here, so a thumb drifting vertically keeps driving it.
  final bool Function(PointerDownEvent event)? allowPointer;
  final double dismissDistance;
  final double dismissVelocity;

  @override
  State<DragToDismiss> createState() => _DragToDismissState();
}

class _DragToDismissState extends State<DragToDismiss>
    with SingleTickerProviderStateMixin {
  /// The surface's downward offset in pixels: the finger sets it during a
  /// drag, a spring carries it home after a cancelled one. Unbounded so the
  /// spring may pass zero.
  late final AnimationController _offset = AnimationController.unbounded(
    vsync: this,
  )..addListener(() => setState(() {}));
  bool _dismissing = false;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  void _onVerticalDragStart(DragStartDetails _) {
    // Catch the surface mid-return where it is.
    _offset.stop();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final wasPast = _offset.value >= widget.dismissDistance;
    _offset.value = math.max(0.0, _offset.value + details.delta.dy);
    // Crossing the distance threshold is felt both ways: releasing past it
    // dismisses, pulling back under it cancels.
    final isPast = _offset.value >= widget.dismissDistance;
    if (isPast && !wasPast) AppHaptics.thresholdOn();
    if (wasPast && !isPast) AppHaptics.thresholdOff();
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    final shouldDismiss =
        _offset.value >= widget.dismissDistance ||
        velocity >= widget.dismissVelocity;
    if (shouldDismiss) {
      _dismissing = true;
      widget.onDismissed();
      return;
    }
    _settleReturn(velocity);
  }

  void _onVerticalDragCancel() {
    _settleReturn(0);
  }

  /// Carries the surface home on the [MotionSpring.spatialFast] spring,
  /// starting at the finger's release [velocity] (pixels per second): a
  /// slow release eases back, an upward flick snaps back. Reduced motion
  /// lands at rest at once.
  void _settleReturn(double velocity) {
    final spring = MotionTokens.spring(context, MotionSpring.spatialFast);
    if (spring == null) {
      _offset.value = 0;
      return;
    }
    _offset.animateWith(
      SpringSimulation(spring, _offset.value, 0, velocity, snapToEnd: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    // An upward flick may carry the spring past rest; the surface stops
    // at its home position rather than lifting off the top.
    final offset = math.max(0.0, _offset.value);
    final progress = (offset / widget.dismissDistance)
        .clamp(0.0, 1.0)
        .toDouble();
    final surface = Transform.translate(
      offset: Offset(0, offset),
      child: Transform.scale(
        scale: 1 - progress * 0.15,
        child: Opacity(
          opacity: 1 - progress * 0.35,
          // The return spring only changes the transform/opacity. Keep
          // the detail surface in its own raster layer so a canceled drag
          // does not rebuild and repaint every image on each reverse tick.
          child: RepaintBoundary(child: widget.child),
        ),
      ),
    );

    final active = widget.enabled && !_dismissing;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        if (active)
          _DismissDragRecognizer:
              GestureRecognizerFactoryWithHandlers<_DismissDragRecognizer>(
                () => _DismissDragRecognizer(debugOwner: this),
                (recognizer) => recognizer
                  ..allowPointer = widget.allowPointer
                  ..onStart = _onVerticalDragStart
                  ..onUpdate = _onVerticalDragUpdate
                  ..onEnd = _onVerticalDragEnd
                  ..onCancel = _onVerticalDragCancel,
              ),
      },
      child: Stack(fit: StackFit.passthrough, children: [surface]),
    );
  }
}

class _DismissDragRecognizer extends VerticalDragGestureRecognizer {
  _DismissDragRecognizer({super.debugOwner});

  bool Function(PointerDownEvent event)? allowPointer;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      (event is! PointerDownEvent || (allowPointer?.call(event) ?? true)) &&
      super.isPointerAllowed(event);
}
