import 'package:flutter/animation.dart';

/// Single source for every UI animation duration and curve. Data-level
/// durations (debounce, frame scheduling, download throttling) do not belong
/// here. Predictive-back / M3 motion hook into these constants in child F.
abstract final class MotionTokens {
  /// Page route transition (ReplicaPageRoute right-in rhythm).
  static const pageTransition = Duration(milliseconds: 300);
  static const pageCurve = Curves.easeInOutCubic;

  /// Short UI transitions (type-selector snap, tab hint fade-in).
  static const fast = Duration(milliseconds: 180);
  static const fastCurve = Curves.easeOut;

  /// Medium UI transitions (root-back exit hint window pieces).
  static const medium = Duration(milliseconds: 200);

  /// Image fade-in inside PixivImage.
  static const imageFade = Duration(milliseconds: 350);
}
