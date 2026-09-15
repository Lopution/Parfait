import 'package:flutter/widgets.dart';

/// Single source for every UI animation duration and curve. Data-level
/// durations (debounce, frame scheduling, download throttling) do not belong
/// here. Predictive-back / M3 motion hook into these constants in child F.
abstract final class MotionTokens {
  /// Page route transition used by the router page builder.
  static const pageTransition = Duration(milliseconds: 300);
  static const pageCurve = Curves.easeInOutCubic;

  /// Short UI transitions (type-selector snap, tab hint fade-in).
  static const fast = Duration(milliseconds: 180);
  static const fastCurve = Curves.easeOut;

  /// Medium UI transitions (root-back exit hint window pieces).
  static const medium = Duration(milliseconds: 200);

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

  /// Reduced-motion gate: collapses [base] to zero when the platform asks
  /// for disabled animations. Reduced motion must remove the flight, never
  /// the state it communicates.
  static Duration resolve(BuildContext context, Duration base) {
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return disabled ? Duration.zero : base;
  }
}
