import 'package:material_ui/material_ui.dart';

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
    this.dismissDistance = 160,
    this.dismissVelocity = 1000,
  });

  final Widget child;
  final VoidCallback onDismissed;
  final bool enabled;
  final double dismissDistance;
  final double dismissVelocity;

  @override
  State<DragToDismiss> createState() => _DragToDismissState();
}

class _DragToDismissState extends State<DragToDismiss>
    with SingleTickerProviderStateMixin {
  late final AnimationController _returnAnimation;
  double _dragOffset = 0;
  double _returnFrom = 0;
  bool _dismissing = false;

  double get _visualOffset => _returnAnimation.isAnimating
      ? _returnFrom * (1 - _returnAnimation.value)
      : _dragOffset;

  @override
  void initState() {
    super.initState();
    _returnAnimation =
        AnimationController(vsync: this, duration: MotionTokens.fast)
          ..addListener(() => setState(() {}))
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              _dragOffset = 0;
            }
          });
  }

  @override
  void dispose() {
    _returnAnimation.dispose();
    super.dispose();
  }

  void _onVerticalDragStart(DragStartDetails _) {
    final offset = _visualOffset;
    _returnAnimation.stop();
    _dragOffset = offset;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragOffset = (_dragOffset + details.delta.dy)
          .clamp(0.0, double.infinity)
          .toDouble();
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final shouldDismiss =
        _dragOffset >= widget.dismissDistance ||
        details.velocity.pixelsPerSecond.dy >= widget.dismissVelocity;
    if (shouldDismiss) {
      _dismissing = true;
      widget.onDismissed();
      return;
    }
    _settleReturn();
  }

  void _onVerticalDragCancel() {
    _settleReturn();
  }

  /// The canceled-drag return flight is the only decorative motion here.
  /// The controller is created in initState (no context), so the
  /// [MotionTokens] gate lives at the call site: reduced motion lands the
  /// end state — `_dragOffset` back to zero via the completed-status
  /// listener — without the flight.
  void _settleReturn() {
    _returnFrom = _dragOffset;
    if (MotionTokens.enabled(context)) {
      _returnAnimation.forward(from: 0);
    } else {
      _returnAnimation.value = 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final offset = _visualOffset;
    final progress = (offset / widget.dismissDistance)
        .clamp(0.0, 1.0)
        .toDouble();
    final surface = Transform.translate(
      offset: Offset(0, offset),
      child: Transform.scale(
        scale: 1 - progress * 0.15,
        child: Opacity(
          opacity: 1 - progress * 0.35,
          // The return controller only changes the transform/opacity. Keep
          // the detail surface in its own raster layer so a canceled drag
          // does not rebuild and repaint every image on each reverse tick.
          child: RepaintBoundary(child: widget.child),
        ),
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: widget.enabled && !_dismissing
          ? _onVerticalDragStart
          : null,
      onVerticalDragUpdate: widget.enabled && !_dismissing
          ? _onVerticalDragUpdate
          : null,
      onVerticalDragEnd: widget.enabled && !_dismissing
          ? _onVerticalDragEnd
          : null,
      onVerticalDragCancel: widget.enabled && !_dismissing
          ? _onVerticalDragCancel
          : null,
      child: Stack(fit: StackFit.passthrough, children: [surface]),
    );
  }
}
