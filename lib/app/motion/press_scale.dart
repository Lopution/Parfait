import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// M3-style press feedback: the child scales to [MotionTokens.pressScale]
/// while a pointer is down and springs back on release. Both directions
/// run the [MotionSpring.spatialFast] spring from the current scale and
/// velocity, so a quick press-release-press never jumps. Passive wrapper —
/// no gestures are consumed, so it composes over the child's own
/// InkWell/GestureDetector. Under reduced motion the scale snaps. The
/// press-feedback setting ([MotionScope.pressFeedbackOf]) turns it off.
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
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = MotionTokens.pressScale,
  });

  final Widget child;
  final bool enabled;

  /// Rest scale while pressed — [MotionTokens.pressScale] for feed cards;
  /// tighter (0.85–0.9) reads better on small touch targets like nav items.
  final double scale;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale>
    with SingleTickerProviderStateMixin, TickerModeWatch {
  /// The rendered scale; unbounded so the spring may pass its target.
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  var _pressed = false;
  var _active = false;
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
    _syncActive();
    _drive();
  }

  /// Only a card off its rest scale has anything to drive.
  @override
  void didChangeTickerMode(bool enabled) {
    if (_pressed || _scale.value != 1) _drive();
  }

  @override
  void didUpdateWidget(PressScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncActive();
  }

  /// A disabled wrapper (by the caller or the press-feedback setting)
  /// drops its Listener: the pointer up never arrives, so a pending delay
  /// or a held press would otherwise outlive it.
  void _syncActive() {
    _active = widget.enabled && MotionScope.pressFeedbackOf(context);
    if (_active) return;
    _pressDelay?.cancel();
    _downPosition = null;
    _pressed = false;
    _scale.value = 1;
  }

  @override
  void dispose() {
    _pressDelay?.cancel();
    _scale.dispose();
    super.dispose();
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    _pressed = value;
    _drive();
  }

  /// Springs from the current scale and velocity toward the target. Frozen
  /// tickers (a route transition owns the ticker budget) hold the neutral
  /// scale: an armed press would bake a mid-release card into the
  /// outgoing snapshot and replay the release after landing — the "card
  /// suddenly grows" pop.
  void _drive() {
    if (!_active) return;
    final target = _pressed && tickersEnabled ? widget.scale : 1.0;
    final spring = tickersEnabled
        ? MotionTokens.spring(context, MotionSpring.spatialFast)
        : null;
    if (spring == null) {
      _scale.value = target;
      return;
    }
    // Snap: a card left at 0.9998 keeps a non-identity transform.
    _scale.animateWith(
      SpringSimulation(
        spring,
        _scale.value,
        target,
        _scale.velocity,
        snapToEnd: true,
      ),
    );
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
    // The pointer stream outlives the widget when the press itself tore
    // it down (a long press that swaps the list it was in): the up event
    // still reaches this Listener after dispose.
    if (!mounted) return;
    _pressDelay?.cancel();
    _downPosition = null;
    _setPressed(false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return widget.child;
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}
