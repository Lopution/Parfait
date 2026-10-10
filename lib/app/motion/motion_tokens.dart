import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../../core/settings/app_settings.dart';

/// Single source for every UI animation duration and curve. Data-level
/// durations (debounce, frame scheduling, download throttling) do not belong
/// here. Read every duration through [resolve] so the animation speed and
/// the reduced-motion gate apply.
abstract final class MotionTokens {
  /// Page route transition at each style's own spec duration (before
  /// [resolve]): FadeForwards behind Android's system style
  /// (`FadeForwardsPageTransitionsBuilder.kTransitionMilliseconds`), the
  /// `CupertinoPageRoute` slide, and [pageTransition] for the system style
  /// elsewhere.
  static Duration pageTransitionOf(
    PageTransitionStyle style, {
    required bool android,
  }) => switch (style) {
    PageTransitionStyle.slide => _pageTransitionSlide,
    PageTransitionStyle.system when android => _pageTransitionFadeForwards,
    PageTransitionStyle.system => pageTransition,
  };

  static const _pageTransitionFadeForwards = Duration(milliseconds: 450);
  static const _pageTransitionSlide = Duration(milliseconds: 500);

  /// `FuncRouteTransition`, the system style off Android.
  static const pageTransition = Duration(milliseconds: 300);
  static const pageCurve = Curves.easeInOutCubic;

  /// Short UI transitions (type-selector snap, tab hint fade-in).
  static const fast = Duration(milliseconds: 180);
  static const fastCurve = Curves.easeOut;

  /// Medium UI transitions.
  static const medium = Duration(milliseconds: 200);

  /// Prompt entrance — Compose M3 `SnackbarHost`: a 150ms linear fade with
  /// a 0.8→1 fast-out-slow-in scale. The exit reverses both over [fast]
  /// rather than Compose's 75ms fade, which read as no animation on device.
  static const promptEnter = Duration(milliseconds: 150);
  static const promptEnterScale = 0.8;
  static const promptScaleCurve = Curves.fastOutSlowIn;

  /// Card press feedback: rest scale while pressed (the motion is the
  /// [MotionSpring.spatialFast] spring).
  static const pressScale = 0.97;

  /// Pill press feedback (tags, chips): tighter than a card's, they are
  /// small targets.
  static const pillPressScale = 0.96;

  /// Alert/confirm dialog presentation.
  static const dialog = Duration(milliseconds: 220);

  /// Home branch switch: the pages slide side by side toward the chosen
  /// destination. The emphasized curve starts gently, so the frame that
  /// builds a first-visited branch hardly moves.
  static const branchSwitch = Duration(milliseconds: 300);
  static const branchSwitchCurve = Curves.easeInOutCubicEmphasized;

  /// In-page tab switch, matching the app bar's kTabScrollDuration.
  static const tabSwitch = Duration(milliseconds: 300);

  /// Scroll hide/show of floating chrome — the shell's bottom bar and the
  /// detail action bar: Shaft's capsule, a 200 ms slide plus fade both
  /// ways on Android's default AccelerateDecelerate interpolator.
  static const chromeScrollHide = Duration(milliseconds: 200);
  static const chromeScrollCurve = Curves.easeInOutSine;

  /// SmoothWheelScroll's per-wheel animated scroll duration.
  static const wheelScroll = Duration(milliseconds: 240);

  /// First-load skeleton shimmer: one shared sweep per skeleton tree.
  static const shimmer = Duration(milliseconds: 1400);

  /// Image load transition: the placeholder dissolves, linearly, off the
  /// image already painted beneath it — Glide's default crossfade (300 ms,
  /// placeholder kept opaque under the incoming image) as Shaft uses it.
  /// Over an opaque image the two layer orders composite identically.
  static const imageFade = Duration(milliseconds: 300);
  static const imageFadeCurve = Curves.linear;

  /// Pull-to-refresh: the indicator shrinks away once the refresh
  /// completes; the list retracts right after.
  static const refreshIndicatorExit = Duration(milliseconds: 200);

  /// The particle burst around a heart that was just added.
  static const bookmarkBurst = Duration(milliseconds: 450);

  /// A setting opened from the settings search: how long its row stays
  /// marked before the mark fades. A dwell, not an animation — it holds
  /// under reduced motion too, so the row is still found.
  static const settingHighlightHold = Duration(milliseconds: 1200);

  /// The fade that clears that mark.
  static const settingHighlightFade = Duration(milliseconds: 600);

  /// Whether motion should play. Three sources, one gate: the platform's
  /// `disableAnimations` (a11y) OR the platform's `reduceMotion`
  /// (iOS "Reduce Motion" does NOT raise `disableAnimations` — reading only
  /// MediaQuery misses it) OR the in-app reduce-motion setting. Any one
  /// collapses decorative motion; none drops the state it communicates.
  static bool enabled(BuildContext context) =>
      _enabled(context, reduce: MotionScope.maybeOf(context) ?? false);

  static bool _enabled(BuildContext context, {required bool reduce}) {
    // The aspect getter: depending on the whole MediaQuery rebuilt every
    // card and image whenever any field changed (insets, the platform's
    // accessibleNavigation flag).
    final disabled = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
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
  /// theme animation), which pass the settings in.
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

  /// Settles in ~150 ms: state fades, selection check marks, the bottom
  /// bar's selected tint.
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

/// Follows the ambient [TickerMode] without depending on it.
///
/// Route transitions and branch switches flip [TickerMode] for a whole
/// page. Each `TickerMode.valuesOf` dependent then rebuilds in that frame,
/// and on a feed that means every card and image at once: the layout
/// spikes at transition start and end. A state that only needs to react to
/// the flip mixes this in, reads [tickersEnabled] and overrides
/// [didChangeTickerMode], rebuilding only if its output actually changes.
mixin TickerModeWatch<T extends StatefulWidget> on State<T> {
  ValueListenable<TickerModeData>? _tickerMode;

  bool get tickersEnabled =>
      (_tickerMode ?? TickerMode.getValuesNotifier(context)).value.enabled;

  /// Called when the ambient mode flips, possibly mid-build of an
  /// ancestor; a `setState` here is allowed.
  @protected
  void didChangeTickerMode(bool enabled) {}

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchTickerMode();
  }

  @override
  void activate() {
    super.activate();
    // Reparented under a different TickerMode.
    _watchTickerMode();
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_onTickerMode);
    _tickerMode = null;
    super.dispose();
  }

  void _watchTickerMode() {
    final notifier = TickerMode.getValuesNotifier(context);
    if (identical(notifier, _tickerMode)) return;
    _tickerMode?.removeListener(_onTickerMode);
    _tickerMode = notifier..addListener(_onTickerMode);
    _onTickerMode();
  }

  /// The mode last reported; forceFrames changes are not reported.
  bool? _reportedEnabled;

  void _onTickerMode() {
    final enabled = _tickerMode!.value.enabled;
    final previous = _reportedEnabled;
    _reportedEnabled = enabled;
    if (previous != null && previous != enabled) didChangeTickerMode(enabled);
  }
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
/// press feedback, page transition style) to the widget subtree. Mounted once at the app root (MaterialApp.builder);
/// tests can wrap any subtree directly. The platform half of the gate stays
/// on `MediaQuery.disableAnimations`.
class MotionScope extends InheritedWidget {
  const MotionScope({
    super.key,
    required this.reduce,
    this.speed = AnimationSpeed.normal,
    this.pressFeedback = true,
    this.transitionStyle = PageTransitionStyle.system,
    required super.child,
  });

  final bool reduce;

  /// Multiplier applied by [MotionTokens.resolve].
  final AnimationSpeed speed;

  /// Whether cards scale down while pressed (`PressScale`).
  final bool pressFeedback;

  /// Transition of pushed pages (`FuncPage`).
  final PageTransitionStyle transitionStyle;

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

  /// The scoped page transition style; [PageTransitionStyle.system]
  /// outside a scope.
  static PageTransitionStyle transitionStyleOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MotionScope>()
          ?.transitionStyle ??
      PageTransitionStyle.system;

  @override
  bool updateShouldNotify(MotionScope oldWidget) =>
      reduce != oldWidget.reduce ||
      speed != oldWidget.speed ||
      pressFeedback != oldWidget.pressFeedback ||
      transitionStyle != oldWidget.transitionStyle;
}
