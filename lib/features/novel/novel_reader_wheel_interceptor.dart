import 'package:flutter/gestures.dart'
    show GestureBinding, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/rendering.dart'
    show BoxHitTestEntry, BoxHitTestResult, HitTestEntry, RenderProxyBox;
import 'package:material_ui/material_ui.dart';

/// Accumulates pointer-wheel / trackpad scroll deltas into discrete page steps
/// with idle reset, direction-reversal reset, and turn cooldown.
class NovelPageWheelAccumulator {
  static const double _threshold = 48;
  static const int _idleResetMs = 300;
  static const int _turnCooldownMs = 150;

  double _accum = 0;
  int? _lastEventMs;
  int? _lastTurnMs;

  void reset() {
    _accum = 0;
  }

  /// Returns `-1`, `1`, or `0` (no turn yet) for [event].
  int stepFor(PointerScrollEvent event) {
    final dx = event.scrollDelta.dx;
    final dy = event.scrollDelta.dy;
    final primaryDelta = dy.abs() >= dx.abs() ? dy : dx;
    if (primaryDelta == 0) return 0;

    final stampMs = event.timeStamp.inMilliseconds;
    if (_lastEventMs != null &&
        stampMs >= _lastEventMs! &&
        stampMs - _lastEventMs! > _idleResetMs) {
      _accum = 0;
    }
    if ((_accum > 0 && primaryDelta < 0) || (_accum < 0 && primaryDelta > 0)) {
      _accum = 0;
    }
    _lastEventMs = stampMs;

    if (_lastTurnMs != null &&
        stampMs >= _lastTurnMs! &&
        stampMs - _lastTurnMs! < _turnCooldownMs) {
      return 0;
    }

    _accum += primaryDelta;
    if (_accum.abs() < _threshold) return 0;

    final delta = _accum > 0 ? 1 : -1;
    _accum = 0;
    _lastTurnMs = stampMs;
    return delta;
  }
}

/// Captures pointer-scroll events before an inner horizontal [PageView]
/// consumes horizontal deltas via raw pixel offsets without page snapping.
class PageWheelInterceptor extends SingleChildRenderObjectWidget {
  const PageWheelInterceptor({
    super.key,
    required this.onPointerScroll,
    required super.child,
  });

  final void Function(PointerScrollEvent event) onPointerScroll;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPageWheelInterceptor(onPointerScroll: onPointerScroll);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderPageWheelInterceptor).onPointerScroll =
        onPointerScroll;
  }
}

class _PageWheelHitTestEntry extends BoxHitTestEntry {
  _PageWheelHitTestEntry(super.target, super.localPosition);

  bool enabled = true;
}

class _RenderPageWheelInterceptor extends RenderProxyBox {
  _RenderPageWheelInterceptor({required this.onPointerScroll});

  void Function(PointerScrollEvent event) onPointerScroll;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    final entry = _PageWheelHitTestEntry(this, position);
    result.add(entry);
    if (!hitTestChildren(result, position: position)) {
      entry.enabled = false;
      return false;
    }
    return true;
  }

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (entry is _PageWheelHitTestEntry &&
        entry.enabled &&
        event is PointerScrollEvent) {
      GestureBinding.instance.pointerSignalResolver.register(event, _resolve);
    }
  }

  void _resolve(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      onPointerScroll(event);
    }
  }
}
