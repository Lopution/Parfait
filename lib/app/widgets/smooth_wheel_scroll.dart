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
/// * Nested scrollables resolve through the hit-test path: an outer wrapper
///   yields only when an inner vertical [RenderViewportBase] under the pointer
///   can actually move in the wheel's direction.
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
  int _scrollGeneration = 0;

  static const _animationDuration = MotionTokens.wheelScroll;

  ScrollController _resolveController(BuildContext context) =>
      widget.controller ??
      PrimaryScrollController.maybeOf(context) ??
      (_fallbackController ??= ScrollController());

  void _interruptWheelScroll() {
    _scrollGeneration++;
    _futurePosition = null;
  }

  @override
  void didUpdateWidget(SmoothWheelScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _interruptWheelScroll();
    }
  }

  @override
  void dispose() {
    _fallbackController?.dispose();
    super.dispose();
  }

  static bool _hasVerticalScrollableAncestor(BuildContext context) {
    var cursor = context;
    while (true) {
      final scrollable = cursor.findAncestorStateOfType<ScrollableState>();
      if (scrollable == null) return false;
      if (axisDirectionToAxis(scrollable.axisDirection) == Axis.vertical) {
        return true;
      }
      cursor = scrollable.context;
    }
  }

  bool _shouldInterceptScroll(PointerScrollEvent signal) {
    if (signal.kind != PointerDeviceKind.mouse) return false;
    if (HardwareKeyboard.instance.isShiftPressed) return false;
    if (signal.scrollDelta.dy == 0) return false;
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
        !_hasVerticalScrollableAncestor(context)) {
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
    final generation = ++_scrollGeneration;
    _futurePosition = target;
    final distance = (target - current).abs();
    if (distance == 0) {
      _futurePosition = null;
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
            // Clear only when no newer wheel tick superseded this animation,
            // so trackpad/scrollbar interruptions clear stale state while
            // older cancelled wheel ticks cannot wipe newer queued targets.
            if (mounted && _scrollGeneration == generation) {
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

    return _WheelSignalInterceptor(
      onInterrupt: _interruptWheelScroll,
      shouldInterceptScroll: _shouldInterceptScroll,
      onHandleScroll: _handlePointerScroll,
      child: widget.builder(context, controller, widget.basePhysics),
    );
  }
}

class _WheelSignalInterceptor extends SingleChildRenderObjectWidget {
  const _WheelSignalInterceptor({
    required this.onInterrupt,
    required this.shouldInterceptScroll,
    required this.onHandleScroll,
    required super.child,
  });

  final VoidCallback onInterrupt;
  final bool Function(PointerScrollEvent event) shouldInterceptScroll;
  final PointerSignalResolvedCallback onHandleScroll;

  @override
  _RenderWheelSignalInterceptor createRenderObject(BuildContext context) =>
      _RenderWheelSignalInterceptor(
        onInterrupt: onInterrupt,
        shouldInterceptScroll: shouldInterceptScroll,
        onHandleScroll: onHandleScroll,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderWheelSignalInterceptor renderObject,
  ) {
    renderObject
      ..onInterrupt = onInterrupt
      ..shouldInterceptScroll = shouldInterceptScroll
      ..onHandleScroll = onHandleScroll;
  }
}

class _WheelHitTestEntry extends BoxHitTestEntry {
  _WheelHitTestEntry(super.target, super.localPosition);

  bool enabled = true;
  List<RenderViewportBase> innerVerticalViewports = const [];
}

class _RenderWheelSignalInterceptor extends RenderProxyBox {
  _RenderWheelSignalInterceptor({
    required this.onInterrupt,
    required this.shouldInterceptScroll,
    required this.onHandleScroll,
  });

  VoidCallback onInterrupt;
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
    entry.innerVerticalViewports = _collectInnerVerticalViewports(
      result.path,
      start,
    );
    return true;
  }

  static List<RenderViewportBase> _collectInnerVerticalViewports(
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
    if (viewports.length < 2) return const [];
    // The last viewport in deepest->outermost order is our wrapped scrollable;
    // collect any earlier vertical viewports to arbitrate at signal time.
    final inner = <RenderViewportBase>[];
    for (var idx = 0; idx < viewports.length - 1; idx++) {
      final vp = viewports[idx];
      if (vp is RenderViewportBase &&
          axisDirectionToAxis(vp.axisDirection) == Axis.vertical) {
        inner.add(vp);
      }
    }
    return inner;
  }

  static bool _hasScrollableInnerViewport(
    List<RenderViewportBase> viewports,
    PointerScrollEvent event,
  ) {
    if (event.scrollDelta.dy == 0) return false;
    for (final vp in viewports) {
      final offset = vp.offset;
      if (offset is! ScrollPosition) return true;
      if (!offset.hasContentDimensions) continue;
      if (!offset.physics.shouldAcceptUserOffset(offset)) continue;
      final dy = vp.axisDirection == AxisDirection.up
          ? -event.scrollDelta.dy
          : event.scrollDelta.dy;
      if (dy > 0 && offset.pixels < offset.maxScrollExtent) return true;
      if (dy < 0 && offset.pixels > offset.minScrollExtent) return true;
    }
    return false;
  }

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (entry is! _WheelHitTestEntry || !entry.enabled) return;
    if (event is PointerDownEvent || event is PointerPanZoomStartEvent) {
      onInterrupt();
    } else if (event is PointerScrollEvent) {
      final hasScrollableInner = _hasScrollableInnerViewport(
        entry.innerVerticalViewports,
        event,
      );
      if (!hasScrollableInner && shouldInterceptScroll(event)) {
        GestureBinding.instance.pointerSignalResolver.register(
          event,
          onHandleScroll,
        );
      } else if (!hasScrollableInner) {
        onInterrupt();
      }
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
