/// Measured chrome of the home shell (read once per frame where the shell
/// builds; the Hero flight reads it when computing its clip).
///
/// The bottom navigation row of the home shell is the only page-chrome
/// value that cannot be statically derived from theme constants — Material
/// 2 BottomAppBar's rendered height depends on the shell build — so the
/// shell measures its own bar and publishes the number here. The Hero
/// flight previously guessed 45 then 64; both left a visible mismatch at
/// the landing moment (a strip of artwork over the bar, or the tile bottom
/// cut short).
class HomeShellMetrics {
  /// Global top edge of the rendered home bottom bar.  Keeping the edge (and
  /// not just a guessed height) matters on devices where the bar includes a
  /// system navigation inset.
  static double? bottomNavTop;

  /// Height of the rendered home bottom bar, retained for diagnostics and as
  /// a conservative fallback before the first frame has been measured.
  static double? bottomNavHeight;
}
