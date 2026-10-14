import 'package:flutter/widgets.dart';

/// Width-based layout breakpoints shared by the shell and content pages,
/// on Material 3's window classes: compact < 600 ≤ medium < 840 ≤ expanded
/// < 1200 ≤ large < 1600 ≤ extra-large. They are pure width thresholds — the
/// shell's NavigationRail, gallery columns and content-width caps all read
/// the same ladder so a resize cannot put chrome and content on different
/// rules.
abstract final class AppBreakpoints {
  /// At and above this the shell swaps the bottom bar for a NavigationRail.
  static const double medium = 600;

  static const double expanded = 840;

  static const double large = 1200;

  /// At and above this the rail widens into a labelled side column; below
  /// it the icon rail leaves the room to the content.
  static const double extraLarge = 1600;

  /// Shell navigation form factor for [width]: rail on medium+ surfaces.
  static bool useNavigationRail(double width) => width >= medium;

  static bool useExtendedRail(double width) => width >= extraLarge;

  /// Detail pages put the artwork and its information side by side when
  /// the area they get (the window less the rail) is wider than tall and at
  /// least medium wide; otherwise they keep the single scroll.
  static bool useTwoPaneDetail(Size content) =>
      content.width >= medium && content.width > content.height;
}
