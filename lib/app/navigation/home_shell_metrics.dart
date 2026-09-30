import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The shell's bottom-bar extent, published as an inherited value by
/// [BranchSlideStack] — the shell computes it synchronously from
/// `FuncBottomNav.restingExtent` and the view padding, so branch pages can
/// reserve the slot on the very first frame instead of waiting for a
/// post-layout measurement.
///
/// Zero on NavigationRail layouts, where no bottom bar exists.
class HomeShellChrome extends InheritedWidget {
  const HomeShellChrome({
    super.key,
    required this.bottomBarExtent,
    required super.child,
  });

  /// Rendered height the shell's floating bottom bar occupies at rest:
  /// `FuncBottomNav.restingExtent(MediaQuery.paddingOf(context).bottom)`,
  /// or 0 while the width ladder selects the NavigationRail.
  final double bottomBarExtent;

  static HomeShellChrome? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeShellChrome>();

  static HomeShellChrome of(BuildContext context) {
    final chrome = maybeOf(context);
    assert(chrome != null, 'HomeShellChrome.of() called outside the shell');
    return chrome!;
  }

  @override
  bool updateShouldNotify(HomeShellChrome oldWidget) =>
      bottomBarExtent != oldWidget.bottomBarExtent;
}

/// Whether the shell's floating bottom bar is currently mounted.
///
/// The only consumer that cannot reach [HomeShellChrome] is the app-level
/// update prompt: the root ScaffoldMessenger sits above the shell, so it
/// needs a plain presence flag rather than an inherited extent. Published
/// by `FuncShellBottomNav` on mount/deactivate — the prompt appears long
/// after first frame, so publish timing is irrelevant.
final homeShellBarVisibleProvider =
    NotifierProvider<_HomeShellBarVisibleNotifier, bool>(
      _HomeShellBarVisibleNotifier.new,
    );

class _HomeShellBarVisibleNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setVisible(bool visible) => state = visible;
}

// TODO(T19): remove — superseded by HomeShellChrome's computed extent.
@immutable
class HomeShellMetrics {
  const HomeShellMetrics({this.bottomNavTop, this.bottomNavHeight});

  final double? bottomNavTop;
  final double? bottomNavHeight;
}

// TODO(T19): remove — see above.
final homeShellMetricsProvider =
    NotifierProvider<_HomeShellMetricsNotifier, HomeShellMetrics>(
      _HomeShellMetricsNotifier.new,
    );

class _HomeShellMetricsNotifier extends Notifier<HomeShellMetrics> {
  @override
  HomeShellMetrics build() => const HomeShellMetrics();

  void publish(double? bottomNavTop, double? bottomNavHeight) {
    state = HomeShellMetrics(
      bottomNavTop: bottomNavTop,
      bottomNavHeight: bottomNavHeight,
    );
  }
}

/// Branches whose root route is currently covered by a pushed route inside
/// the branch Navigator. The shell-level bottom bar subscribes to this and
/// slides away while the current branch is covered — the same layering
/// Shaft gets by pushing a whole Activity over the home ViewPager.
///
/// Reported by [BranchRootScaffold], which subscribes to its branch's
/// RouteObserver: `didPushNext`/`didPopNext` fire at push/pop start, so the
/// bar animates in step with the route transition rather than after it.
final branchStackCoveredProvider =
    NotifierProvider<_BranchStackCoveredNotifier, Set<int>>(
      _BranchStackCoveredNotifier.new,
    );

class _BranchStackCoveredNotifier extends Notifier<Set<int>> {
  @override
  Set<int> build() => const {};

  void setCovered(int branchIndex, bool covered) {
    if (state.contains(branchIndex) == covered) return;
    state = {
      for (final b in state)
        if (b != branchIndex) b,
      if (covered) branchIndex,
    };
  }
}
