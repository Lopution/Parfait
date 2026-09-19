import 'package:flutter/widgets.dart';

/// Single source for every UI animation duration and curve. Data-level
/// durations (debounce, frame scheduling, download throttling) do not belong
/// here. Predictive-back / M3 motion hook into these constants in child F.
abstract final class MotionTokens {
  /// Page route transition used by the router page builder.
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

  /// Card press feedback: scale down on pointer-down, release back.
  static const press = Duration(milliseconds: 120);
  static const pressCurve = Curves.easeOut;
  static const pressScale = 0.97;

  /// Feed entrance: staggered fade + short rise, played on a card's first
  /// viewport exposure. Cards arriving mid-fling stay static — a pop-in
  /// during ballistic scroll reads as a layout bug, not motion.
  static const listEntrance = Duration(milliseconds: 220);
  static const listEntranceCurve = Curves.easeOutCubic;
  static const listEntranceOffset = 12.0;
  static const listStaggerStep = Duration(milliseconds: 30);

  /// Bottom-sheet presentation (sheetAnimationStyle).
  static const sheet = Duration(milliseconds: 250);
  static const sheetCurve = Curves.easeOutCubic;

  /// Alert/confirm dialog presentation.
  static const dialog = Duration(milliseconds: 220);

  /// Bottom-nav indicator sweep, matching the app bar's kTabScrollDuration.
  static const navIndicator = Duration(milliseconds: 300);

  /// Landing-ink replay timing on the branch-swap bottom bar: how long the
  /// synthetic press holds before confirming, and the pressed-highlight fade.
  static const inkHold = Duration(milliseconds: 130);
  static const inkFade = Duration(milliseconds: 200);

  /// SmoothWheelScroll's per-wheel animated scroll duration.
  static const wheelScroll = Duration(milliseconds: 240);

  /// Image fade-in inside PixivImage. 500ms matches CachedNetworkImage's
  /// default and PixEz; PixShaft's Glide crossfade is 300ms.
  static const imageFade = Duration(milliseconds: 500);

  /// Feed-card fade-in — shorter than [imageFade] so a settling grid does
  /// not leave a long trail of animating tiles behind a scroll.
  static const imageFadeFeed = Duration(milliseconds: 300);

  /// Placeholder fade-out under the incoming frame. This must outlive
  /// [imageFade]: the disappearing layer finishing first leaves the
  /// half-transparent new frame over the page background for the rest of
  /// the fade — the white flash on a quality-tier swap. PixEz uses 1000ms
  /// for exactly this reason.
  static const imageFadeOut = Duration(milliseconds: 1000);

  /// Whether motion should play. Two sources, one gate: the platform's
  /// `disableAnimations` (a11y) OR the in-app reduce-motion setting. Either
  /// one collapses decorative motion; neither drops the state it
  /// communicates.
  static bool enabled(BuildContext context) {
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final reduced = MotionScope.maybeOf(context) ?? false;
    return !disabled && !reduced;
  }

  /// Reduced-motion gate: collapses [base] to zero when either source asks
  /// for disabled animations. Reduced motion must remove the flight, never
  /// the state it communicates.
  static Duration resolve(BuildContext context, Duration base) {
    return enabled(context) ? base : Duration.zero;
  }
}

/// Publishes the in-app reduce-motion setting to the widget subtree. Mounted
/// once at the app root (MaterialApp.builder); tests can wrap any subtree
/// directly. The platform half of the gate stays on
/// `MediaQuery.disableAnimations`.
class MotionScope extends InheritedWidget {
  const MotionScope({super.key, required this.reduce, required super.child});

  final bool reduce;

  static bool? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MotionScope>()?.reduce;

  @override
  bool updateShouldNotify(MotionScope oldWidget) => reduce != oldWidget.reduce;
}
