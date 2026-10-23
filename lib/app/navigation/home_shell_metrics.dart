import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The shell's bottom-bar extent, published as an inherited value by
/// [HomeBranchStack] — the shell computes it synchronously from
/// `FuncBottomNav.restingExtent` and the view padding, so branch pages can
/// reserve the slot on the very first frame instead of waiting for a
/// post-layout measurement.
///
/// Also the channel between the shell bar and the branch roots: a root
/// page reports its user's scrolling through [onBranchRootScroll] and,
/// while a route covers it, draws the bar itself from [bottomBarVisibility]
/// (see `BranchRootScaffold`).
///
/// Zero on NavigationRail layouts, where no bottom bar exists.
class HomeShellChrome extends InheritedWidget {
  const HomeShellChrome({
    super.key,
    required this.bottomBarExtent,
    this.railExtent = 0,
    required this.bottomBarVisibleExtent,
    required this.bottomBarVisibility,
    required this.onBranchRootScroll,
    required super.child,
  });

  /// Rendered height the shell's floating bottom bar occupies at rest:
  /// `FuncBottomNav.restingExtent(MediaQuery.paddingOf(context).bottom)`,
  /// or 0 while the width ladder selects the NavigationRail.
  final double bottomBarExtent;

  /// Width the rail and its divider take beside the branches; 0 on
  /// bottom-bar layouts and while an immersive page hides the rail.
  final double railExtent;

  /// The collapsed rail's width (Material 3's navigation rail).
  static const double railWidth = 80;

  /// The labelled rail's width on extra-large windows.
  static const double extendedRailWidth = 256;

  /// The area a page gets: the window less the rail. A page outside the
  /// shell, pushed over it, gets the whole window.
  static Size contentSizeOf(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    final rail = maybeOf(context)?.railExtent ?? 0;
    return Size(window.width - rail, window.height);
  }

  /// The bar's *currently visible* height at the screen bottom, resolved
  /// from its scroll hide by `FuncShellBottomNav`. The Hero landing clip
  /// reads it per frame so a half-returned bar clips at its real top edge
  /// instead of the resting one; the bar also anchors prompts with it
  /// (`PromptAnchor`).
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

  /// The bar's scroll hide, 1 shown and 0 hidden, linear (see
  /// `ScrollHiddenChrome`). Stable, like [bottomBarVisibleExtent].
  final Animation<double> bottomBarVisibility;

  /// Scroll notifications of the current branch's root page: the user's
  /// scrolling there, and nowhere else, hides and shows the bar.
  final NotificationListenerCallback<ScrollNotification> onBranchRootScroll;

  /// The same chrome over [child].
  HomeShellChrome over(Widget child) => HomeShellChrome(
    bottomBarExtent: bottomBarExtent,
    railExtent: railExtent,
    bottomBarVisibleExtent: bottomBarVisibleExtent,
    bottomBarVisibility: bottomBarVisibility,
    onBranchRootScroll: onBranchRootScroll,
    child: child,
  );

  static HomeShellChrome? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeShellChrome>();

  static HomeShellChrome of(BuildContext context) {
    final chrome = maybeOf(context);
    assert(chrome != null, 'HomeShellChrome.of() called outside the shell');
    return chrome!;
  }

  @override
  bool updateShouldNotify(HomeShellChrome oldWidget) =>
      bottomBarExtent != oldWidget.bottomBarExtent ||
      railExtent != oldWidget.railExtent ||
      bottomBarVisibility != oldWidget.bottomBarVisibility;
}

/// Branches whose root route is covered: a route sits on it inside the
/// branch Navigator, or a page transition over it has not settled. The
/// shell bar steps aside for the current branch while it is, and the root
/// page draws the bar instead, so the pages pushed over it cover it.
///
/// Reported by `BranchRootScaffold` from its route's state.
final branchStackCoveredProvider =
    NotifierProvider<_BranchStackCoveredNotifier, Set<int>>(
      _BranchStackCoveredNotifier.new,
    );

class _BranchStackCoveredNotifier extends Notifier<Set<int>> {
  /// Covered scaffold → its branch. A branch can hold two root scaffolds
  /// for a moment (one leaving as its page is replaced); the branch is
  /// covered while either reports so.
  final _owners = <Object, int>{};

  @override
  Set<int> build() {
    _owners.clear();
    return const {};
  }

  void setCovered(Object owner, int branchIndex, bool covered) {
    if (covered) {
      _owners[owner] = branchIndex;
    } else {
      _owners.remove(owner);
    }
    final next = _owners.values.toSet();
    if (setEquals(next, state)) return;
    state = next;
  }
}

/// Whether an immersive page hides the shell's rail. On a phone the pages
/// pushed over a branch root cover the bottom bar; on rail layouts the rail
/// stays beside them, so a page that wants the whole window (the novel
/// reader) asks for it here while its route is the current one.
final shellRailHiddenProvider = NotifierProvider<ShellRailHiddenNotifier, bool>(
  ShellRailHiddenNotifier.new,
);

class ShellRailHiddenNotifier extends Notifier<bool> {
  final _owners = <Object>{};

  @override
  bool build() {
    _owners.clear();
    return false;
  }

  void setHidden(Object owner, bool hidden) {
    // A release deferred past the owner's dispose can outlive the scope.
    if (!ref.mounted) return;
    if (hidden) {
      _owners.add(owner);
    } else {
      _owners.remove(owner);
    }
    if (state != _owners.isNotEmpty) state = _owners.isNotEmpty;
  }
}
