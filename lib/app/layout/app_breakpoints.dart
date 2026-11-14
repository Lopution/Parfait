import 'package:flutter/widgets.dart';

import 'window_layout_spec.dart';

/// Width-based layout breakpoints shared by the shell and content pages,
/// on Material 3's window classes: compact < 600 ≤ medium < 840 ≤ expanded
/// < 1200 ≤ large < 1600 ≤ extra-large. They are pure width thresholds — the
/// shell's rail, gallery columns and content-width caps all read the same
/// ladder so a resize cannot put chrome and content on different rules.
/// The one exception is the phone tier ([isPhoneDisplay]), read from the
/// display: it keeps a turned phone on the bottom bar (`FormFactor`).
abstract final class AppBreakpoints {
  /// At and above this the shell swaps the bottom bar for the rail, except
  /// on a phone (`FormFactor.hasRail`).
  static const double medium = 600;

  static const double expanded = 840;

  static const double large = 1200;

  /// At and above this a PC's rail opens into its labelled panel until the
  /// user toggles it (`FormFactor.railExpanded`).
  static const double extraLarge = 1600;

  /// The logical size of the whole display the app is on: the most room
  /// its window can ever get, whatever the window has now (split screen,
  /// a pop-up window). Android reports the activity's maximum window
  /// bounds, so it changes when a foldable folds, not when a window is
  /// split. Null when the embedder reports no display size; callers then
  /// decide by the window alone.
  static Size? displaySizeOf(BuildContext context) {
    final override = WindowEnvironmentOverride.maybeOf(context)?.displaySize;
    if (override != null) return override;
    final display = View.of(context).display;
    if (display.size.isEmpty) return null;
    return display.size / display.devicePixelRatio;
  }

  /// A phone: a display whose shortest side is under [medium]. Turned
  /// sideways it is still a phone and keeps the bottom bar, however wide
  /// the window. An unknown display ([displaySizeOf] null) is not one.
  static bool isPhoneDisplay(Size? display) =>
      display != null && display.shortestSide < medium;

  /// Below this height a window is short (Material 3's compact height): a
  /// phone held sideways.
  static const double compactHeight = 480;

  /// Form pages put their header beside the form instead of above it on a
  /// short window that is at least medium wide.
  static bool useSideBySideForm(Size window) =>
      window.height < compactHeight && window.width >= medium;

  /// Detail pages put the artwork and its information side by side when
  /// [content] is at least [compactHeight] tall and either in a foldable
  /// posture ([FoldPosture.book] or [FoldPosture.tabletop]) or in a
  /// landscape / near-square window at least [medium] wide
  /// (`height / width < 1.2`). Tall portrait windows keep the single-column
  /// article layout (DETAIL-18).
  static bool useTwoPaneDetail(
    Size content, {
    FoldPosture posture = FoldPosture.flat,
  }) =>
      content.height >= compactHeight &&
      (posture != FoldPosture.flat ||
          (content.width >= medium && content.height / content.width < 1.2));

  /// Convenience variant of [useTwoPaneDetail] that reads the ambient
  /// [FoldPosture] from [context].
  static bool useTwoPaneDetailOf(BuildContext context, Size content) =>
      useTwoPaneDetail(content, posture: WindowLayoutSpec.postureOf(context));
}
