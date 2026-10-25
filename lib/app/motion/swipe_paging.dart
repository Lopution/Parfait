import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform/app_root_pipeline_owner.dart';
import 'motion_tokens.dart';

/// The steepest swipe, in degrees off the horizontal, that a sideways pager
/// takes; a steeper one is left to the vertical list under it.
const swipePagingMaxDegrees = 40.0;

final _maxSlope = math.tan(swipePagingMaxDegrees * math.pi / 180);

/// A horizontal drag that starts once the finger has moved the device's
/// touch slop sideways while leaning no more than [swipePagingMaxDegrees]
/// off the horizontal. A vertical list starts at the same slop on its own
/// axis, so a swipe within the angle reaches the pager first and a steeper
/// one the list. A horizontal scrollable inside the pager starts on the
/// same move and, deeper in the tree, wins it.
class SwipePagingRecognizer extends HorizontalDragGestureRecognizer {
  SwipePagingRecognizer({super.debugOwner});

  /// Asked with the finger's sideways travel when the swipe would start:
  /// true leaves it to an enclosing pager ([SwipePagerScope]).
  bool Function(double dx)? yieldsTo;

  /// Asked on each pointer down: false ignores the pointer.
  bool Function()? allowsPointer;

  final _downAt = <int, Offset>{};
  Offset _moved = Offset.zero;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      (allowsPointer?.call() ?? true) && super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _downAt[event.pointer] = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final down = _downAt[event.pointer];
    if (event is PointerMoveEvent && down != null) {
      _moved = event.position - down;
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    final dx = _moved.dx.abs();
    if (dx <= computeHitSlop(pointerDeviceKind, gestureSettings) ||
        _moved.dy.abs() > dx * _maxSlope) {
      return false;
    }
    return !(yieldsTo?.call(_moved.dx) ?? false);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _downAt.clear();
    _moved = Offset.zero;
    super.didStopTrackingLastPointer(pointer);
  }
}

/// The pager around a nested one, which hands it a swipe at its first or
/// last page, as a ViewPager inside another gives up a swipe it cannot
/// scroll. The choice is made when the swipe starts, never during it.
class SwipePagerScope extends InheritedWidget {
  const SwipePagerScope({
    super.key,
    required this.canPage,
    required super.child,
  });

  /// Whether this pager takes a swipe towards later pages ([forward]) or
  /// earlier ones now.
  final bool Function(bool forward) canPage;

  static SwipePagerScope? maybeOf(BuildContext context) =>
      context.getElementForInheritedWidgetOfExactType<SwipePagerScope>()?.widget
          as SwipePagerScope?;

  @override
  bool updateShouldNotify(SwipePagerScope oldWidget) => false;
}

/// Pages a finger moves sideways ([swipeGestures]) and a spring settles
/// from the release speed. The host reports where its pages are
/// ([pagePosition], in pages), draws a position ([showPagePosition]; one
/// before the first page or after the last is the rubber band's
/// overscroll) and takes the landing ([landOnPage]). The index a host
/// keeps changes only there, once per swipe.
///
/// A release lands on the nearest page, or on the next one in a fling's
/// direction from where the pages are, as ViewPager picks: a fling back
/// from past halfway returns to the page it left rather than skipping it.
/// Semantics hold while the pages move: each frame would otherwise move
/// every node on them.
mixin SwipePaging<T extends StatefulWidget> on State<T>, TickerProvider {
  static const minFlingVelocity = 400.0;

  int get pageCount;
  double get pagePosition;
  void showPagePosition(double position);
  void landOnPage(int page);

  AnimationController? _settle;
  int _settleTarget = 0;
  bool _dragging = false;
  VoidCallback? _releaseSemantics;

  bool get pageSettling => _settle?.isAnimating ?? false;

  bool get _ltr => Directionality.of(context) == TextDirection.ltr;

  double get _extent =>
      (context.findRenderObject() as RenderBox?)?.size.width ?? 0;

  /// [child] under the paging drag.
  Widget swipeGestures({
    required Widget child,
    bool Function(double dx)? yieldsTo,
    bool Function()? allowsPointer,
  }) {
    final multitouch = ScrollConfiguration.of(
      context,
    ).getMultitouchDragStrategy(context);
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        SwipePagingRecognizer:
            GestureRecognizerFactoryWithHandlers<SwipePagingRecognizer>(
              () => SwipePagingRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..onStart = pageDragStart
                ..onUpdate = _onDragUpdate
                ..onEnd = _onDragEnd
                ..onCancel = _onDragCancel
                ..multitouchDragStrategy = multitouch
                ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
                ..yieldsTo = yieldsTo
                ..allowsPointer = allowsPointer,
            ),
      },
      child: child,
    );
  }

  /// A swipe took the pages; overrides call this first.
  @protected
  void pageDragStart(DragStartDetails details) {
    _settle?.stop();
    _dragging = true;
    _releaseSemantics ??= AppRootPipelineOwner.holdSemantics();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final extent = _extent;
    if (!_dragging || extent <= 0 || pageCount < 1) return;
    final delta = (_ltr ? -details.delta.dx : details.delta.dx) / extent;
    showPagePosition(_resisted(pagePosition, delta));
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final extent = _extent;
    final velocity = details.primaryVelocity ?? 0;
    final pagesPerSecond = extent <= 0
        ? 0.0
        : (_ltr ? -velocity : velocity) / extent;
    final position = pagePosition;
    final target = velocity.abs() >= minFlingVelocity
        ? (pagesPerSecond > 0 ? position.ceil() : position.floor())
        : position.round();
    settlePagesTo(
      target.clamp(0, pageCount - 1),
      pagesPerSecond: pagesPerSecond,
    );
  }

  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    settlePagesTo(pagePosition.round().clamp(0, pageCount - 1));
  }

  /// [position] moved by [delta] pages; past the first or last page the
  /// move meets [BouncingScrollPhysics]'s friction, growing as the pages
  /// go further out, so the rubber band matches the lists'.
  double _resisted(double position, double delta) {
    final last = math.max(pageCount - 1, 0).toDouble();
    final next = position + delta;
    if (next >= 0 && next <= last) return next;
    final edge = next < 0 ? 0.0 : last;
    final before = position - edge;
    final after = next - edge;
    if (before * after <= 0) return edge + after * _friction(0);
    if (after.abs() <= before.abs()) return next;
    return position + delta * _friction(before.abs());
  }

  static double _friction(double overscroll) =>
      const BouncingScrollPhysics().frictionFactor(math.min(overscroll, 1));

  /// Carries the pages to [target] on the [MotionSpring.spatialDefault]
  /// spring, starting at [pagesPerSecond]: a fling lands without slowing
  /// first, and a spring-back turns round instead of stalling.
  void settlePagesTo(int target, {double pagesPerSecond = 0}) {
    final from = pagePosition;
    _settleTarget = target;
    final spring = MotionTokens.spring(context, MotionSpring.spatialDefault);
    if (spring == null || (from - target).abs() < 1e-4) {
      _settle?.stop();
      _land(target);
      return;
    }
    final controller = _settle ??= AnimationController.unbounded(vsync: this)
      ..addListener(_applySettle)
      ..addStatusListener(_finishSettle);
    _releaseSemantics ??= AppRootPipelineOwner.holdSemantics();
    controller.animateWith(
      SpringSimulation(
        spring,
        from,
        target.toDouble(),
        pagesPerSecond,
        snapToEnd: true,
        tolerance: _tolerance(),
      ),
    );
  }

  /// Done within half a pixel, in pages: the default tolerance ran the
  /// spring on through a tenth of a second of sub-pixel motion, and the
  /// landing, the index and the bar's selection waited for it.
  Tolerance _tolerance() {
    final halfPixel = 0.5 / _extent;
    return Tolerance(distance: halfPixel, velocity: halfPixel / 0.05);
  }

  /// Drops a swipe in flight: its settle stops where it is, unlanded.
  void stopPaging() {
    _dragging = false;
    _settle?.stop();
    _releaseHold();
  }

  void _applySettle() => showPagePosition(_settle!.value);

  void _finishSettle(AnimationStatus status) {
    if (status == AnimationStatus.completed) _land(_settleTarget);
  }

  void _land(int page) {
    _releaseHold();
    landOnPage(page);
  }

  void _releaseHold() {
    _releaseSemantics?.call();
    _releaseSemantics = null;
  }

  @override
  void dispose() {
    _settle?.dispose();
    _releaseHold();
    super.dispose();
  }
}
