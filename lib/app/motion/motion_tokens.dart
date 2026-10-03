import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../../core/settings/app_settings.dart';

/// Single source for every UI animation duration and curve. Data-level
/// durations (debounce, frame scheduling, download throttling) do not belong
/// here. Read every duration through [resolve] so the animation speed and
/// the reduced-motion gate apply.
abstract final class MotionTokens {
  /// Page route transition used by the router page builder on Android.
  static const pageTransitionAndroid = Duration(milliseconds: 350);

  /// Page route transition on the other platforms.
  static const pageTransition = Duration(milliseconds: 300);
  static const pageCurve = Curves.easeInOutCubic;

  /// Modal page transition (search input): short bottom-edge slide + fade.
  static const modalTransition = Duration(milliseconds: 260);
  static const modalCurve = Curves.easeOutCubic;
  static const modalSlideBegin = Offset(0, 0.06);

  /// Short UI transitions (type-selector snap, tab hint fade-in).
  static const fast = Duration(milliseconds: 180);
  static const fastCurve = Curves.easeOut;

  /// Medium UI transitions (root-back exit hint window pieces).
  static const medium = Duration(milliseconds: 200);

  /// Card press feedback: rest scale while pressed (the motion is the
  /// [MotionSpring.spatialFast] spring).
  static const pressScale = 0.97;

  /// Feed entrance: staggered fade, played on a card's first viewport
  /// exposure. Cards arriving mid-fling stay static — a pop-in during
  /// ballistic scroll reads as a layout bug, not motion.
  static const listEntrance = Duration(milliseconds: 220);
  static const listEntranceCurve = Curves.easeOutCubic;
  static const listStaggerStep = Duration(milliseconds: 30);

  /// Bottom-sheet presentation (sheetAnimationStyle).
  static const sheet = Duration(milliseconds: 250);
  static const sheetCurve = Curves.easeOutCubic;

  /// Alert/confirm dialog presentation.
  static const dialog = Duration(milliseconds: 220);

  /// Bottom-nav indicator sweep, matching the app bar's kTabScrollDuration.
  static const navIndicator = Duration(milliseconds: 300);

  /// Bottom-nav scroll hide/show — Material `HideViewOnScrollBehavior`
  /// timings and interpolators: slide-in (show) decelerates over 225ms
  /// (linear-out-slow-in = cubic-bezier(0, 0, 0.2, 1)), slide-out (hide)
  /// accelerates away over 175ms (fast-out-linear-in = (0.4, 0, 1, 1)).
  static const navBarShow = Duration(milliseconds: 225);
  static const navBarShowCurve = Cubic(0, 0, 0.2, 1);
  static const navBarHide = Duration(milliseconds: 175);
  static const navBarHideCurve = Cubic(0.4, 0, 1, 1);

  /// Landing-ink replay timing on the branch-swap bottom bar: how long the
  /// synthetic press holds before confirming, and the pressed-highlight fade.
  static const inkHold = Duration(milliseconds: 130);
  static const inkFade = Duration(milliseconds: 200);

  /// SmoothWheelScroll's per-wheel animated scroll duration.
  static const wheelScroll = Duration(milliseconds: 240);

  /// First-load skeleton shimmer: one shared sweep per skeleton tree.
  static const shimmer = Duration(milliseconds: 1400);

  /// Image fade-in inside PixivImage. 500ms matches CachedNetworkImage's
  /// default; Glide's crossfade is 300ms.
  static const imageFade = Duration(milliseconds: 500);

  /// Feed-card fade-in — shorter than [imageFade] so a settling grid does
  /// not leave a long trail of animating tiles behind a scroll.
  static const imageFadeFeed = Duration(milliseconds: 300);

  /// Placeholder fade-out under the incoming frame. This must outlive
  /// [imageFade]: the disappearing layer finishing first leaves the
  /// half-transparent new frame over the page background for the rest of
  /// the fade — the white flash on a quality-tier swap.
  static const imageFadeOut = Duration(milliseconds: 1000);

  /// Whether motion should play. Three sources, one gate: the platform's
  /// `disableAnimations` (a11y) OR the platform's `reduceMotion`
  /// (iOS "Reduce Motion" does NOT raise `disableAnimations` — reading only
  /// MediaQuery misses it) OR the in-app reduce-motion setting. Any one
  /// collapses decorative motion; none drops the state it communicates.
  static bool enabled(BuildContext context) =>
      _enabled(context, reduce: MotionScope.maybeOf(context) ?? false);

  static bool _enabled(BuildContext context, {required bool reduce}) {
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final platformReduce =
        View.maybeOf(
          context,
        )?.platformDispatcher.accessibilityFeatures.reduceMotion ??
        false;
    return !disabled && !reduce && !platformReduce;
  }

  /// Every UI animation length goes through here: [base] scaled by the
  /// animation speed, or zero when the reduced-motion gate is closed.
  /// Reduced motion must remove the flight, never the state it
  /// communicates.
  static Duration resolve(BuildContext context, Duration base) => resolveWith(
    context,
    base,
    reduce: MotionScope.maybeOf(context) ?? false,
    speed: MotionScope.speedOf(context),
  );

  /// [resolve] for the few callers above [MotionScope] (the MaterialApp
  /// theme animation, the root messenger), which pass the settings in.
  static Duration resolveWith(
    BuildContext context,
    Duration base, {
    required bool reduce,
    required AnimationSpeed speed,
  }) => _enabled(context, reduce: reduce) ? base * speed.factor : Duration.zero;

  /// [token] as a physical spring at the current animation speed, or null
  /// when the reduced-motion gate is closed (callers jump to the end
  /// value). Stretching time by f is the same spring with stiffness / f²
  /// at an unchanged damping ratio.
  static SpringDescription? spring(BuildContext context, MotionSpring token) {
    if (!enabled(context)) return null;
    final f = MotionScope.speedOf(context).factor;
    return SpringDescription.withDampingRatio(
      mass: 1,
      stiffness: token.stiffness / (f * f),
      ratio: token.dampingRatio,
    );
  }

  /// [token] as a duration plus curve, for APIs that only take those
  /// (bottom sheets, AnimatedSize). The duration is the spring's settle
  /// time at the current speed; zero when the gate is closed.
  static (Duration, Curve) springCurve(
    BuildContext context,
    MotionSpring token,
  ) {
    final description = spring(context, token);
    if (description == null) return (Duration.zero, Curves.linear);
    final curve = SpringCurve(description);
    return (curve.settleDuration, curve);
  }
}

/// Material 3 spring tokens as (damping ratio, stiffness), mass 1, from
/// androidx `StandardMotionTokens` / `ExpressiveMotionTokens`. Spatial
/// springs move position, scale and size; effects springs fade opacity
/// and colour. Only tokens with a caller are listed. Read them through
/// [MotionTokens.spring] or [MotionTokens.springCurve].
enum MotionSpring {
  /// Settles in ~225 ms: press, expand/collapse, removal collapse.
  spatialFast(0.9, 1400),

  /// Settles in ~320 ms: bottom sheet.
  spatialDefault(0.9, 700),

  /// Settles in ~150 ms: state fades, selection check marks.
  effectsFast(1.0, 3800),

  /// Underdamped (~9% overshoot, ~390 ms): the bookmark heart pop.
  expressiveSpatialFast(0.6, 800);

  const MotionSpring(this.dampingRatio, this.stiffness);

  final double dampingRatio;
  final double stiffness;
}

/// A 0 → 1 spring at rest velocity, normalised onto [0, 1] time: t = 1 is
/// the settle time, the earliest moment the spring is within 0.001 of 1 and
/// nearly still. `transform(1)` is exactly 1 (the [Curve] contract), so an
/// animation ending on this curve never stops a pixel short.
class SpringCurve extends Curve {
  SpringCurve(SpringDescription description)
    : _simulation = SpringSimulation(
        description,
        0,
        1,
        0,
        // Velocity tolerance in units of the natural frequency: a spring
        // stretched in time by f then settles exactly f times later.
        tolerance: Tolerance(
          distance: _distanceTolerance,
          velocity:
              _distanceTolerance *
              math.sqrt(description.stiffness / description.mass),
        ),
      ) {
    _settleSeconds = _findSettle(_simulation);
  }

  static const _distanceTolerance = 0.001;

  /// Search step and ceiling for the settle time.
  static const _step = 0.001;
  static const _maxSeconds = 10.0;

  final SpringSimulation _simulation;
  late final double _settleSeconds;

  Duration get settleDuration =>
      Duration(microseconds: (_settleSeconds * 1e6).round());

  static double _findSettle(SpringSimulation simulation) {
    for (var t = _step; t < _maxSeconds; t += _step) {
      if (simulation.isDone(t)) return t;
    }
    return _maxSeconds;
  }

  @override
  double transformInternal(double t) => _simulation.x(t * _settleSeconds);
}

/// Programmatic page turn (keyboard, tap zones): slides over the resolved
/// [MotionTokens.fast], or jumps when the motion gate is closed — a scroll
/// animation asserts a non-zero duration.
void turnPage(BuildContext context, PageController controller, int page) {
  final duration = MotionTokens.resolve(context, MotionTokens.fast);
  if (duration > Duration.zero) {
    controller.animateToPage(
      page,
      duration: duration,
      curve: MotionTokens.fastCurve,
    );
  } else {
    controller.jumpToPage(page);
  }
}

/// Publishes the in-app motion settings (reduce motion, animation speed,
/// press feedback) to the widget subtree. Mounted once at the app root (MaterialApp.builder);
/// tests can wrap any subtree directly. The platform half of the gate stays
/// on `MediaQuery.disableAnimations`.
class MotionScope extends InheritedWidget {
  const MotionScope({
    super.key,
    required this.reduce,
    this.speed = AnimationSpeed.normal,
    this.pressFeedback = true,
    required super.child,
  });

  final bool reduce;

  /// Multiplier applied by [MotionTokens.resolve].
  final AnimationSpeed speed;

  /// Whether cards scale down while pressed (`PressScale`).
  final bool pressFeedback;

  static bool? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MotionScope>()?.reduce;

  /// The scoped animation speed; outside a scope (a bare MaterialApp in
  /// tests) the normal tier applies.
  static AnimationSpeed speedOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MotionScope>()?.speed ??
      AnimationSpeed.normal;

  /// The scoped press-feedback switch; on outside a scope.
  static bool pressFeedbackOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MotionScope>()
          ?.pressFeedback ??
      true;

  @override
  bool updateShouldNotify(MotionScope oldWidget) =>
      reduce != oldWidget.reduce ||
      speed != oldWidget.speed ||
      pressFeedback != oldWidget.pressFeedback;
}
