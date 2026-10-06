import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The shell's bottom-bar extent, published as an inherited value by
/// [HomeBranchStack] — the shell computes it synchronously from
/// `FuncBottomNav.restingExtent` and the view padding, so branch pages can
/// reserve the slot on the very first frame instead of waiting for a
/// post-layout measurement.
///
/// Zero on NavigationRail layouts, where no bottom bar exists.
class HomeShellChrome extends InheritedWidget {
  const HomeShellChrome({
    super.key,
    required this.bottomBarExtent,
    required this.bottomBarVisibleExtent,
    required super.child,
  });

  /// Rendered height the shell's floating bottom bar occupies at rest:
  /// `FuncBottomNav.restingExtent(MediaQuery.paddingOf(context).bottom)`,
  /// or 0 while the width ladder selects the NavigationRail.
  final double bottomBarExtent;

  /// The bar's *currently visible* height at the screen bottom — the two
  /// stacked slide-out animations (route cover + scroll auto-hide) are
  /// resolved into one live value by `FuncShellBottomNav`. The Hero
  /// landing clip reads it per frame so a half-returned bar clips at its
  /// real top edge instead of the resting one; the bar also anchors
  /// prompts with it (`PromptAnchor`).
  ///
  /// The instance is a stable notifier owned by `HomeBranchStack`;
  /// [updateShouldNotify] deliberately ignores it. Stays 0 on rail
  /// layouts, where no bottom bar exists.
  ///
  /// Read `.value` only — never rebuild on it. `FuncShellBottomNav` writes
  /// it from its own `build`, so a listener that rebuilds would mark
  /// widgets dirty mid-build; relayout-only listeners (the prompt layout)
  /// are safe.
  final ValueListenable<double> bottomBarVisibleExtent;

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

/// Branches whose root route is currently covered by a pushed route inside
/// the branch Navigator. The shell-level bottom bar subscribes to this and
/// slides away while the current branch is covered, as if a whole new
/// screen had been pushed over the home pager.
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
