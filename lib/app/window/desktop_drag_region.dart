import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Draggable desktop title-bar strip supporting window dragging and
/// double-click zoom/restore.
///
/// On macOS, [GestureDetector.onPanStart] waits for [kPanSlop] (18dp) plus
/// gesture-arena resolution, which drops fast short drags before AppKit sees
/// the mouse event. A dedicated primary-button [Listener] starts dragging as
/// soon as pointer movement exceeds [_macDragThreshold] (3dp) while preserving
/// double-click detection and child hit-testing.
class DesktopDragRegion extends StatefulWidget {
  const DesktopDragRegion({
    super.key,
    required this.child,
    this.onStartDragging,
    this.onDoubleTap,
    this.behavior = HitTestBehavior.opaque,
    this.platformOverride,
  });

  final Widget child;
  final VoidCallback? onStartDragging;
  final VoidCallback? onDoubleTap;
  final HitTestBehavior behavior;
  final TargetPlatform? platformOverride;

  @override
  State<DesktopDragRegion> createState() => _DesktopDragRegionState();
}

class _DesktopDragRegionState extends State<DesktopDragRegion> {
  static const double _macDragThreshold = 3.0;
  static const double _doubleTapMaxDistance = 6.0;
  static const Duration _doubleTapMaxGap = kDoubleTapTimeout;

  int? _activePointer;
  Offset? _pointerDownPosition;
  bool _dragTriggered = false;
  DateTime? _lastTapUpTime;
  Offset? _lastTapUpPosition;

  void _resetPointer() {
    _activePointer = null;
    _pointerDownPosition = null;
    _dragTriggered = false;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.buttons & kPrimaryMouseButton == 0) return;
    _activePointer = event.pointer;
    _pointerDownPosition = event.position;
    _dragTriggered = false;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_activePointer != event.pointer || _dragTriggered) return;
    if (event.buttons & kPrimaryMouseButton == 0) {
      _resetPointer();
      return;
    }
    final down = _pointerDownPosition;
    if (down == null) return;
    if ((event.position - down).distance >= _macDragThreshold) {
      _dragTriggered = true;
      _lastTapUpTime = null;
      _lastTapUpPosition = null;
      widget.onStartDragging?.call();
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_activePointer != event.pointer) return;
    final dragged = _dragTriggered;
    _resetPointer();
    if (dragged || widget.onDoubleTap == null) return;

    final now = DateTime.now();
    final prevTime = _lastTapUpTime;
    final prevPos = _lastTapUpPosition;
    if (prevTime != null &&
        prevPos != null &&
        now.difference(prevTime) <= _doubleTapMaxGap &&
        (event.position - prevPos).distance <= _doubleTapMaxDistance) {
      _lastTapUpTime = null;
      _lastTapUpPosition = null;
      widget.onDoubleTap?.call();
      return;
    }
    _lastTapUpTime = now;
    _lastTapUpPosition = event.position;
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_activePointer == event.pointer) {
      _resetPointer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final platform = widget.platformOverride ?? Theme.of(context).platform;
    if (platform == TargetPlatform.macOS) {
      return Listener(
        behavior: widget.behavior,
        onPointerDown:
            widget.onStartDragging == null && widget.onDoubleTap == null
            ? null
            : _handlePointerDown,
        onPointerMove: widget.onStartDragging == null
            ? null
            : _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        child: widget.child,
      );
    }
    return GestureDetector(
      behavior: widget.behavior,
      onPanStart: widget.onStartDragging == null
          ? null
          : (_) => widget.onStartDragging!(),
      onDoubleTap: widget.onDoubleTap,
      child: widget.child,
    );
  }
}
