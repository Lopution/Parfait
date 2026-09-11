/// Width-based layout breakpoints shared by the shell and content pages.
/// These are pure width thresholds — the shell's NavigationRail, gallery
/// columns, and any future content-width caps all read the same ladder so a
/// resize cannot put chrome and content on different rules.
abstract final class AppBreakpoints {
  /// Below this the shell uses the bottom `NavigationBar` (compact M3).
  static const double compact = 600;

  /// At and above this the shell switches to `NavigationRail`; settings stays
  /// a peer entry in the rail's trailing slot.
  static const double medium = 600;

  /// At and above this the rail stays, and content pages may cap their
  /// readable column — feeds keep flowing edge-to-edge.
  static const double expanded = 1200;

  /// Shell navigation form factor for [width]: rail on medium+ surfaces.
  static bool useNavigationRail(double width) => width >= medium;
}
