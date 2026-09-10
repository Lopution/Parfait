import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Measured chrome of the home shell (read once per frame where the shell
/// builds; the Hero flight reads it when computing its clip).
///
/// The bottom navigation row of the home shell is the only page-chrome
/// value that cannot be statically derived from theme constants — the
/// NavigationBar's rendered height depends on the shell build — so the
/// shell measures its own bar and publishes the number here. The Hero flight
/// previously guessed 45 then 64; both left a visible mismatch at the landing
/// moment (a strip of artwork over the bar, or the tile bottom cut short).
@immutable
class HomeShellMetrics {
  const HomeShellMetrics({this.bottomNavTop, this.bottomNavHeight});

  /// Global top edge of the rendered home bottom bar.  Keeping the edge (and
  /// not just a guessed height) matters on devices where the bar includes a
  /// system navigation inset.
  final double? bottomNavTop;

  /// Height of the rendered home bottom bar, retained for diagnostics and as
  /// a conservative fallback before the first frame has been measured.
  final double? bottomNavHeight;
}

/// Single owner of the measured home-shell chrome. [HomePage] publishes the
/// measurement; the detail Hero flight reads it without a rebuild dependency.
final homeShellMetricsProvider =
    NotifierProvider<_HomeShellMetricsNotifier, HomeShellMetrics>(
      _HomeShellMetricsNotifier.new,
    );

class _HomeShellMetricsNotifier extends Notifier<HomeShellMetrics> {
  @override
  HomeShellMetrics build() => const HomeShellMetrics();

  void publish(double bottomNavTop, double bottomNavHeight) {
    state = HomeShellMetrics(
      bottomNavTop: bottomNavTop,
      bottomNavHeight: bottomNavHeight,
    );
  }
}
