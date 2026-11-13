import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform/platform_caps.dart';
import '../motion/motion_tokens.dart';

/// Turns discrete mouse-wheel ticks into an animated scroll instead of the
/// default fixed-step jump while keeping touch drags, Shift+wheel, and
/// precision trackpad `PointerPanZoom` gestures 100% native.
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
/// * `_WheelSignalInterceptor` places a [HitTestEntry] before children are
///   processed during hit-testing and checks whether any inner vertical
///   [RenderViewportBase] under the pointer can scroll. When no inner vertical
///   scrollable claims the tick, `SmoothWheelScroll` registers discrete
///   non-Shift mouse `PointerScrollEvent`s with
///   [GestureBinding.instance.pointerSignalResolver] ahead of its wrapped
///   [Scrollable], so `Scrollable`'s instant jump never runs and `basePhysics`
///   never degrades to `NeverScrollableScrollPhysics`.
/// * Consecutive ticks accumulate into one target ([_futurePosition]) so a
///   fast wheel stays continuous, and the animation duration shrinks as the
///   target nears a clamped edge. Downward wheel ticks while already at the
///   bottom edge dispatch a `ScrollUpdateNotification` so `LoadMoreListener`
///   can still request pagination.
/// * Nested wrapped scrollables coordinate through [_ScrollWheelState]: the
///   innermost wrapper under the pointer wins.
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
  ScrollController? _fallbackController;
  ScrollController? _activeController;
  double? _futurePosition;

  // Nested-wrapper arbitration: a descendant SmoothWheelScroll under the
  // pointer marks itself active in this scope, so this wrapper's own wheel
  // handler stays out of the way.
  final Set<int> _activeChildren = {};
  _ScrollWheelState? _parent;
  final int _id = _nextId++;
  static int _nextId = 0;

  static const _animationDuration = MotionTokens.wheelScroll;

  ScrollController _resolveController(BuildContext context) =>
      widget.controller ??
      PrimaryScrollController.maybeOf(context) ??
      (_fallbackController ??= ScrollController());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _parent = _ScrollWheelState.maybeOf(context);
  }

  @override
  void didUpdateWidget(SmoothWheelScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _futurePosition = null;
    }
  }

  @override
  void dispose() {
    _parent?.onChildInactive(_id);
    _fallbackController?.dispose();
    super.dispose();
  }

  bool _shouldInterceptScroll(PointerScrollEvent signal) {
    if (signal.kind != PointerDeviceKind.mouse) return false;
    if (HardwareKeyboard.instance.isShiftPressed) return false;
    if (signal.scrollDelta.dy == 0) return false;
    // A wrapped descendant scrollable under the pointer owns the tick.
    if (_activeChildren.isNotEmpty) return false;
    final controller = _activeController;
    if (controller == null || !controller.hasClients) return false;

    final position = controller.position;
    final current = position.pixels;
    final canMove = signal.scrollDelta.dy > 0
        ? current < position.maxScrollExtent
        : current > position.minScrollExtent;
    if (canMove) return true;
    // Assist pagination when already sitting at the bottom edge of a root feed.
    if (signal.scrollDelta.dy > 0 &&
        current >= position.maxScrollExtent &&
        context.findAncestorStateOfType<ScrollableState>() == null) {
      return true;
    }
    return false;
  }

  void _handlePointerScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final controller = _activeController;
    if (controller == null || !controller.hasClients) return;

    final position = controller.position;
    final current = position.pixels;
    _futurePosition ??= current;

    // Later ticks in the same stream reach progressively further, so a fast
    // wheel does not stall at a fixed per-tick distance.
    final k = (_futurePosition! - current).abs() / 1600 + 1;
    final raw = _futurePosition! + event.scrollDelta.dy * k;
    final target = raw.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _futurePosition = target;
    final distance = (target - current).abs();
    if (distance == 0) {
      if (event.scrollDelta.dy > 0 && current >= position.maxScrollExtent) {
        final notifyContext = position.context.notificationContext;
        if (notifyContext != null && notifyContext.mounted) {
          ScrollUpdateNotification(
            metrics: position.copyWith(),
            context: notifyContext,
            scrollDelta: 0.0,
          ).dispatch(notifyContext);
        }
      }
      event.respond(allowPlatformDefault: false);
      return;
    }

    event.respond(allowPlatformDefault: false);

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
      controller
          .animateTo(target, duration: duration, curve: Curves.linear)
          .then((_) {
            // The accumulator only clears when nothing newer superseded it —
            // otherwise an old animation completing would drop queued ticks.
            if (mounted &&
                _futurePosition == target &&
                controller.hasClients &&
                controller.position.pixels == target) {
              _futurePosition = null;
            }
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _resolveController(context);
    _activeController = controller;

    // Wheel smoothing is a desktop affordance; on touch platforms this is a
    // transparent pass-through while preserving the controller fallback.
    if (!PlatformCaps.system().isDesktop) {
      return widget.builder(context, controller, widget.basePhysics);
    }

    Widget child = _WheelSignalInterceptor(
      onPointerDown: () => _futurePosition = null,
      shouldInterceptScroll: _shouldInterceptScroll,
      onHandleScroll: _handlePointerScroll,
      child: _ScrollWheelState(
        onChildActive: _activeChildren.add,
        onChildInactive: _activeChildren.remove,
        child: widget.builder(context, controller, widget.basePhysics),
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

class _WheelSignalInterceptor extends SingleChildRenderObjectWidget {
  const _WheelSignalInterceptor({
    required this.onPointerDown,
    required this.shouldInterceptScroll,
    required this.onHandleScroll,
    required super.child,
  });

  final VoidCallback onPointerDown;
  final bool Function(PointerScrollEvent event) shouldInterceptScroll;
  final PointerSignalResolvedCallback onHandleScroll;

  @override
  _RenderWheelSignalInterceptor createRenderObject(BuildContext context) =>
      _RenderWheelSignalInterceptor(
        onPointerDown: onPointerDown,
        shouldInterceptScroll: shouldInterceptScroll,
        onHandleScroll: onHandleScroll,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderWheelSignalInterceptor renderObject,
  ) {
    renderObject
      ..onPointerDown = onPointerDown
      ..shouldInterceptScroll = shouldInterceptScroll
      ..onHandleScroll = onHandleScroll;
  }
}

class _WheelHitTestEntry extends BoxHitTestEntry {
  _WheelHitTestEntry(super.target, super.localPosition);

  bool enabled = true;
  bool innerVerticalScrollable = false;
}

class _RenderWheelSignalInterceptor extends RenderProxyBox {
  _RenderWheelSignalInterceptor({
    required this.onPointerDown,
    required this.shouldInterceptScroll,
    required this.onHandleScroll,
  });

  VoidCallback onPointerDown;
  bool Function(PointerScrollEvent event) shouldInterceptScroll;
  PointerSignalResolvedCallback onHandleScroll;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    final start = result.path.length + 1;
    final entry = _WheelHitTestEntry(this, position);
    result.add(entry);
    final hitChild = hitTestChildren(result, position: position);
    if (!hitChild) {
      entry.enabled = false;
      return false;
    }
    entry.innerVerticalScrollable = _hasInnerVerticalScrollable(
      result.path,
      start,
    );
    return true;
  }

  static bool _hasInnerVerticalScrollable(
    Iterable<HitTestEntry> path,
    int startIndex,
  ) {
    final viewports = <RenderAbstractViewport>[];
    var i = 0;
    for (final entry in path) {
      if (i++ >= startIndex && entry.target is RenderAbstractViewport) {
        viewports.add(entry.target as RenderAbstractViewport);
      }
    }
    if (viewports.length < 2) return false;
    // The last viewport in deepest->outermost order is our wrapped scrollable;
    // any earlier vertical scrollable that can actually scroll owns the tick.
    for (var idx = 0; idx < viewports.length - 1; idx++) {
      final vp = viewports[idx];
      if (vp is RenderViewportBase) {
        final isVertical =
            vp.axisDirection == AxisDirection.down ||
            vp.axisDirection == AxisDirection.up;
        if (!isVertical) continue;
        final offset = vp.offset;
        if (offset is ScrollPosition &&
            offset.hasContentDimensions &&
            offset.maxScrollExtent <= offset.minScrollExtent) {
          continue;
        }
        return true;
      }
    }
    return false;
  }

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (entry is! _WheelHitTestEntry || !entry.enabled) return;
    if (event is PointerDownEvent) {
      onPointerDown();
    } else if (event is PointerScrollEvent &&
        !entry.innerVerticalScrollable &&
        shouldInterceptScroll(event)) {
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        onHandleScroll,
      );
    }
  }
}

/// Retains pointer presence while suppressing hover highlight updates during
/// active scrolling of any ancestor [Scrollable]. Once scrolling stops, a
/// pointer resting inside becomes hovered without requiring mouse movement.
class ScrollAwareHoverRegion extends StatefulWidget {
  const ScrollAwareHoverRegion({
    super.key,
    required this.onHover,
    required this.child,
    this.cursor = MouseCursor.defer,
  });

  final ValueChanged<bool> onHover;
  final Widget child;
  final MouseCursor cursor;

  @override
  State<ScrollAwareHoverRegion> createState() => _ScrollAwareHoverRegionState();
}

class _ScrollAwareHoverRegionState extends State<ScrollAwareHoverRegion> {
  final Set<ScrollPosition> _positions = {};
  ValueListenable<TickerModeData>? _tickerMode;
  bool _pointerInside = false;
  bool _hovered = false;
  bool _checkScheduled = false;

  bool get _active => _tickerMode?.value.enabled ?? true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextTicker = TickerMode.getValuesNotifier(context);
    if (!identical(nextTicker, _tickerMode)) {
      _tickerMode?.removeListener(_onTickerChanged);
      _tickerMode = nextTicker..addListener(_onTickerChanged);
    }
    if (_pointerInside) {
      _syncScrollPositions();
      _updateHover();
    }
  }

  void _onTickerChanged() {
    if (!_active) {
      _clearScrollPositions();
      if (_hovered) {
        _hovered = false;
        widget.onHover(false);
      }
    } else if (_pointerInside) {
      _syncScrollPositions();
      _updateHover();
    }
  }

  void _syncScrollPositions() {
    final positions = <ScrollPosition>{};
    if (_active && _pointerInside) {
      context.visitAncestorElements((element) {
        if (element is StatefulElement && element.state is ScrollableState) {
          positions.add((element.state as ScrollableState).position);
        }
        return true;
      });
    }
    for (final position in _positions.difference(positions)) {
      position.isScrollingNotifier.removeListener(_updateHover);
    }
    for (final position in positions.difference(_positions)) {
      position.isScrollingNotifier.addListener(_updateHover);
    }
    _positions
      ..clear()
      ..addAll(positions);
  }

  void _clearScrollPositions() {
    for (final position in _positions) {
      position.isScrollingNotifier.removeListener(_updateHover);
    }
    _positions.clear();
  }

  void _updateHover() {
    if (!mounted) return;
    final hovered =
        _pointerInside &&
        _active &&
        !_positions.any((position) => position.isScrollingNotifier.value);
    if (hovered == _hovered) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_checkScheduled) return;
      _checkScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkScheduled = false;
        if (mounted) _updateHover();
      });
      return;
    }
    _hovered = hovered;
    widget.onHover(hovered);
  }

  void _setPointerInside(bool inside) {
    if (_pointerInside == inside) return;
    _pointerInside = inside;
    _syncScrollPositions();
    _updateHover();
  }

  @override
  void deactivate() {
    _clearScrollPositions();
    super.deactivate();
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_onTickerChanged);
    _clearScrollPositions();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.cursor,
    onEnter: (_) => _setPointerInside(true),
    onExit: (_) => _setPointerInside(false),
    child: widget.child,
  );
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
