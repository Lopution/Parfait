import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform/platform_caps.dart';
import '../motion/motion_tokens.dart';

/// Turns mouse-wheel ticks into an animated scroll instead of the default
/// fixed-step jump (desktop UX: wheels without tick detents and precision
/// pads both land mid-step). Touch/stylus input is untouched.
///
/// Usage:
/// ```dart
/// SmoothWheelScroll(
///   controller: existingController,      // optional
///   basePhysics: AlwaysScrollable...,    // optional; null keeps platform default
///   builder: (context, controller, physics) => CustomScrollView(
///     controller: controller,
///     physics: physics,
///     slivers: [...],
///   ),
/// )
/// ```
///
/// How it works:
///
/// * `Listener.onPointerSignal` is delivered to *every* Listener on the hit
///   path, while `Scrollable` only registers its own wheel handler with the
///   pointer-signal resolver when its physics accepts user offsets. So the
///   wrapper keeps the scrollable on [NeverScrollableScrollPhysics] while
///   the mouse is in "wheel mode" — the scrollable never registers, the
///   ancestor Listener sees every tick, and there is no double-scroll.
/// * The mouse moving over the scrollable, or a wheel tick, enters wheel
///   mode; a pointer down drops it so touch, stylus and trackpad drags
///   scroll normally. It starts off: on a touchscreen there is no hover,
///   and a scrollable on [NeverScrollableScrollPhysics] has no drag
///   recognizer, so the first touch would be lost. A tick that arrives
///   before the wheel physics is built is the scrollable's own jump: its
///   `pointerScroll` idles the animation started here.
/// * Consecutive ticks accumulate into one target ([_futurePosition]) so a
///   fast wheel stays continuous, and the animation duration shrinks as the
///   target nears a clamped edge.
/// * Nested wrapped scrollables coordinate through [_ScrollWheelState]: the
///   innermost wrapper under the pointer wins, matching how nested
///   scrollables resolve wheel events natively.
///
/// On non-desktop platforms the widget is a transparent pass-through.
class SmoothWheelScroll extends StatefulWidget {
  const SmoothWheelScroll({
    super.key,
    this.controller,
    this.basePhysics,
    required this.builder,
  });

  final ScrollController? controller;
  final ScrollPhysics? basePhysics;
  final Widget Function(
    BuildContext context,
    ScrollController controller,
    ScrollPhysics? physics,
  )
  builder;

  @override
  State<SmoothWheelScroll> createState() => _SmoothWheelScrollState();
}

class _SmoothWheelScrollState extends State<SmoothWheelScroll> {
  late final ScrollController _controller =
      widget.controller ?? ScrollController();

  bool _wheelMode = false;
  double? _futurePosition;

  // Nested-wrapper arbitration: a descendant SmoothWheelScroll under the
  // pointer marks itself active in this scope, so this wrapper's own wheel
  // handler stays out of the way.
  final Set<int> _activeChildren = {};
  _ScrollWheelState? _parent;
  final int _id = _nextId++;
  static int _nextId = 0;

  static const _animationDuration = MotionTokens.wheelScroll;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _parent = _ScrollWheelState.maybeOf(context);
  }

  @override
  void dispose() {
    _parent?.onChildInactive(_id);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent) return;
    if (signal.kind != PointerDeviceKind.mouse) return;
    if (HardwareKeyboard.instance.isShiftPressed) return;
    // A wrapped descendant scrollable under the pointer owns the tick.
    if (_activeChildren.isNotEmpty) return;
    if (!_controller.hasClients) return;

    _enterWheelMode();

    final position = _controller.position;
    final current = position.pixels;
    _futurePosition ??= current;

    // Later ticks in the same stream reach progressively further, so a fast
    // wheel does not stall at a fixed per-tick distance.
    final k = (_futurePosition! - current).abs() / 1600 + 1;
    final raw = _futurePosition! + signal.scrollDelta.dy * k;
    final target = raw.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _futurePosition = target;
    final distance = (target - current).abs();
    if (distance == 0) return;

    // Shrink the animation when the clamped target is closer than the raw
    // accumulator implied, so edge hits feel crisp instead of slow.
    var duration = _animationDuration;
    final span = (raw - current).abs();
    if (span > 0 && distance < span) {
      duration *= distance / span;
      if (duration < const Duration(milliseconds: 10)) {
        duration = const Duration(milliseconds: 10);
      }
    }

    unawaited(
      _controller
          .animateTo(target, duration: duration, curve: Curves.linear)
          .then((_) {
            // The accumulator only clears when nothing newer superseded it —
            // otherwise an old animation completing would drop queued ticks.
            if (_futurePosition == target &&
                _controller.position.pixels == target) {
              _futurePosition = null;
            }
          }),
    );
  }

  void _enterWheelMode() {
    if (!_wheelMode) setState(() => _wheelMode = true);
  }

  @override
  Widget build(BuildContext context) {
    // Wheel smoothing is a desktop affordance; on touch platforms this is a
    // transparent pass-through — including the scrollable's controller:
    // handing it our private controller would detach it from the
    // PrimaryScrollController the page relied on before this wrapper
    // existed.
    if (!PlatformCaps.system().isDesktop) {
      return widget.builder(
        context,
        widget.controller ??
            PrimaryScrollController.maybeOf(context) ??
            _controller,
        widget.basePhysics,
      );
    }

    Widget child = Listener(
      onPointerDown: (_) {
        _futurePosition = null;
        if (_wheelMode) setState(() => _wheelMode = false);
      },
      onPointerHover: (event) {
        if (event.kind == PointerDeviceKind.mouse) _enterWheelMode();
      },
      onPointerSignal: _onPointerSignal,
      child: _ScrollWheelState(
        onChildActive: _activeChildren.add,
        onChildInactive: _activeChildren.remove,
        child: widget.builder(
          context,
          _controller,
          _wheelMode
              ? const NeverScrollableScrollPhysics()
              : widget.basePhysics,
        ),
      ),
    );

    if (_parent != null) {
      final parent = _parent!;
      child = MouseRegion(
        onEnter: (_) => parent.onChildActive(_id),
        onExit: (_) => parent.onChildInactive(_id),
        child: child,
      );
    }
    return child;
  }
}

/// Registers descendant [SmoothWheelScroll]s that currently sit under the
/// pointer, so only the innermost wrapper animates on a wheel tick.
class _ScrollWheelState extends InheritedWidget {
  const _ScrollWheelState({
    required this.onChildActive,
    required this.onChildInactive,
    required super.child,
  });

  final void Function(int id) onChildActive;
  final void Function(int id) onChildInactive;

  static _ScrollWheelState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ScrollWheelState>();

  @override
  bool updateShouldNotify(_ScrollWheelState oldWidget) => false;
}
