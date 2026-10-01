import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// M3-style press feedback: the child scales to [MotionTokens.pressScale]
/// while a pointer is down and releases back over [MotionTokens.press].
/// Passive wrapper — no gestures are consumed, so it composes over the
/// child's own InkWell/GestureDetector. Under reduced motion the scale
/// snaps via a zero duration rather than animating.
///
/// Release uses a raw [Listener] rather than a tap recognizer: a recognizer's
/// `onTapDown` waits on the `kPressTimeout` deadline or an arena win (up to
/// ~100ms of press latency), and its `onTapCancel` only fires once tapDown
/// already ran — a scroll takeover before that deadline would report
/// nothing at all. The arena never notifies losers either way, so the
/// takeover is detected here instead: once the drag delta along an ancestor
/// Scrollable's axis passes [kTouchSlop], that scrollable has claimed the
/// gesture and the press releases.
///
/// Inside a Scrollable the press itself still waits [kPressTimeout]: most
/// touches there are swipes that cross the slop within it, and pressing at
/// once would run a scale-down and a release across the card under the
/// finger on every swipe start. A tap shorter than the deadline shows no
/// scale; the tap's own feedback (ink, route push) covers it.
///
/// [TickerMode] frozen (a route transition owns the ticker budget): render
/// the neutral scale. A press scale left armed would bake a mid-release
/// card into the outgoing snapshot and replay the release after landing —
/// the "card suddenly grows" pop.
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = MotionTokens.pressScale,
    this.curve = MotionTokens.pressCurve,
  });

  final Widget child;
  final bool enabled;

  /// Rest scale while pressed — [MotionTokens.pressScale] for feed cards;
  /// tighter (0.85–0.9) reads better on small touch targets like nav items.
  final double scale;

  /// Applied in both directions — an overshooting curve (e.g.
  /// `Curves.easeOutBack`) gives the release a springy pop.
  final Curve curve;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  var _pressed = false;
  Offset? _downPosition;
  Timer? _pressDelay;
  bool _insideVerticalScrollable = false;
  bool _insideHorizontalScrollable = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _insideVerticalScrollable =
        Scrollable.maybeOf(context, axis: Axis.vertical) != null;
    _insideHorizontalScrollable =
        Scrollable.maybeOf(context, axis: Axis.horizontal) != null;
  }

  @override
  void didUpdateWidget(PressScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A disabled wrapper drops its Listener: the pointer up never arrives,
    // so a pending delay or a held press would otherwise outlive it.
    if (!widget.enabled) {
      _pressDelay?.cancel();
      _downPosition = null;
      _pressed = false;
    }
  }

  @override
  void dispose() {
    _pressDelay?.cancel();
    super.dispose();
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  void _onPointerDown(PointerDownEvent event) {
    _downPosition = event.position;
    if (!_insideVerticalScrollable && !_insideHorizontalScrollable) {
      _setPressed(true);
      return;
    }
    _pressDelay?.cancel();
    _pressDelay = Timer(kPressTimeout, () => _setPressed(true));
  }

  void _onPointerMove(PointerMoveEvent event) {
    final origin = _downPosition;
    if (origin == null) return;
    final delta = event.position - origin;
    // The pointer keeps streaming to this Listener after a Scrollable's
    // drag recognizer wins the arena — the claim itself is what matters,
    // so release exactly at the axis the scrollable owns once the delta
    // crosses the same slop the recognizer uses.
    if ((delta.dy.abs() > kTouchSlop && _insideVerticalScrollable) ||
        (delta.dx.abs() > kTouchSlop && _insideHorizontalScrollable)) {
      _release();
    }
  }

  void _onPointerEnd(PointerEvent event) => _release();

  void _release() {
    _pressDelay?.cancel();
    _downPosition = null;
    _setPressed(false);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final tickersEnabled = TickerMode.valuesOf(context).enabled;
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: AnimatedScale(
        scale: _pressed && tickersEnabled ? widget.scale : 1,
        duration: tickersEnabled
            ? MotionTokens.resolve(context, MotionTokens.press)
            : Duration.zero,
        curve: widget.curve,
        child: widget.child,
      ),
    );
  }
}
