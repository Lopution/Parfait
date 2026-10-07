import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/navigation/route_observer.dart';
import '../../l10n/context.dart';
import '../motion/motion_tokens.dart';
import '../icons/app_icons.dart';
import '../navigation/home_shell_metrics.dart';
import '../theme/func_semantic_tokens.dart';
import 'fit_label.dart';
import 'prompt_anchor.dart';

/// The five home destinations in branch order, shared by the bottom bar
/// and the wide-layout navigation rail.
List<FuncBottomNavDestination> homeDestinations(BuildContext context) => [
  FuncBottomNavDestination(
    icon: AppIcons.home,
    label: context.l10n.homeRecommended,
  ),
  FuncBottomNavDestination(
    icon: AppIcons.ranking,
    label: context.l10n.homeRanking,
  ),
  FuncBottomNavDestination(icon: AppIcons.n, label: context.l10n.newTitle),
  FuncBottomNavDestination(
    icon: AppIcons.search,
    label: context.l10n.searchTitle,
  ),
  FuncBottomNavDestination(
    icon: Icons.person_outline,
    label: context.l10n.homeMe,
  ),
];

/// Primary bottom navigation for narrow layouts, an M3 navigation bar:
/// 64dp tall with a 56×32 pill indicator behind the selected destination's
/// icon. Only the pill paints ink — the whole cell still takes the tap,
/// the same split `NavigationBar` makes through its `_IndicatorInkWell`.
class FuncBottomNav extends StatelessWidget {
  const FuncBottomNav({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<FuncBottomNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// M3 navigation bar indicator: a 56×32 stadium behind the icon.
  static const Size indicatorSize = Size(56, 32);
  static const double _height = 64;

  /// Rendered height the bar occupies at rest: the fixed row plus the
  /// bottom safe-area inset [SafeArea] adds underneath it. The shell's
  /// chrome slot, branch-page spacers and the Hero landing clip all derive
  /// from this one formula, so they agree on the first frame without
  /// measuring the laid-out bar.
  static double restingExtent(double bottomSafeInset) =>
      _height + bottomSafeInset;

  /// Room for a label inside its destination.
  static double _labelSlot(double itemWidth) =>
      math.max(0.0, itemWidth - 2 * _labelInset);

  static const double _labelInset = 6.0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final navTheme = NavigationBarTheme.of(context);
    return Material(
      color: colors.surfaceContainerLowest,
      child: SafeArea(
        top: false,
        // The labels are exempt from the user's text scale past
        // NavigationBar's own 1.3 ceiling — measurement and drawing read
        // the same clamped scaler inside.
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: SizedBox(
            height: _height,
            child: Semantics(
              role: ui.SemanticsRole.tabBar,
              explicitChildNodes: true,
              container: true,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // The ambient default lives below this widget's Material —
                  // read it here so labels inherit the app font, not whatever
                  // style floats above the shell.
                  final ambient = DefaultTextStyle.of(context).style;
                  // The theme's label style merged over the ambient keeps the
                  // inherited font family; state colours never change
                  // metrics, so one resolution serves the group's fit
                  // measurement.
                  final measureStyle = ambient.merge(
                    navTheme.labelTextStyle?.resolve(const <WidgetState>{}),
                  );
                  final itemWidth = constraints.maxWidth / destinations.length;
                  // Uniform label scale: every destination shares one
                  // size, shrunk until the widest translation fits its
                  // slot, down to LabelFit.minScale; past that the labels
                  // ellipsize.
                  final fit = LabelFit.group(
                    labels: [for (final d in destinations) d.label],
                    style: measureStyle,
                    textScaler: MediaQuery.textScalerOf(context),
                    textDirection: Directionality.of(context),
                    slotWidth: _labelSlot(itemWidth),
                  );
                  return Row(
                    children: [
                      for (var i = 0; i < destinations.length; i++)
                        Expanded(
                          child: MergeSemantics(
                            child: Semantics(
                              role: ui.SemanticsRole.tab,
                              selected: i == selectedIndex,
                              child: _FuncBottomNavItem(
                                destination: destinations[i],
                                index: i,
                                count: destinations.length,
                                selected: i == selectedIndex,
                                ambientStyle: ambient,
                                labelFit: fit,
                                onTap: () => onSelected(i),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FuncBottomNavDestination {
  const FuncBottomNavDestination({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// Destination overlay mirroring `_TabsPrimaryDefaultsM3`: pressed always
/// resolves primary 10%; hover/focus split on selected like the TabBar's
/// tabs. Shared by every item's ink response.
Color? _resolveDestinationOverlay(ColorScheme colors, Set<WidgetState> states) {
  if (states.contains(WidgetState.selected)) {
    if (states.contains(WidgetState.pressed)) {
      return colors.primary.withValues(alpha: 0.1);
    }
    if (states.contains(WidgetState.hovered)) {
      return colors.primary.withValues(alpha: 0.08);
    }
    if (states.contains(WidgetState.focused)) {
      return colors.primary.withValues(alpha: 0.1);
    }
    return null;
  }
  if (states.contains(WidgetState.pressed)) {
    return colors.primary.withValues(alpha: 0.1);
  }
  if (states.contains(WidgetState.hovered)) {
    return colors.onSurface.withValues(alpha: 0.08);
  }
  if (states.contains(WidgetState.focused)) {
    return colors.onSurface.withValues(alpha: 0.1);
  }
  return null;
}

/// One destination cell: an icon over its label, vertically centred in the
/// 64dp row. Owns the selection animation behind its pill so selecting a
/// destination grows the pill from its centre — the M3 indicator expand.
class _FuncBottomNavItem extends StatefulWidget {
  const _FuncBottomNavItem({
    required this.destination,
    required this.index,
    required this.count,
    required this.selected,
    required this.ambientStyle,
    required this.labelFit,
    required this.onTap,
  });

  final FuncBottomNavDestination destination;
  final int index;
  final int count;
  final bool selected;

  /// The ambient default text style; the theme's resolved label style is
  /// merged over it so the label keeps the inherited font family.
  final TextStyle ambientStyle;
  final LabelFit labelFit;
  final VoidCallback onTap;

  @override
  State<_FuncBottomNavItem> createState() => _FuncBottomNavItemState();
}

class _FuncBottomNavItemState extends State<_FuncBottomNavItem>
    with SingleTickerProviderStateMixin {
  /// Locates the pill for [_PillInkWell]'s rect callback.
  final GlobalKey _pillKey = GlobalKey();
  late final AnimationController _selection;

  @override
  void initState() {
    super.initState();
    _selection = AnimationController(
      vsync: this,
      value: widget.selected ? 1 : 0,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _selection.duration = MotionTokens.resolve(
      context,
      MotionTokens.navDestination,
    );
  }

  @override
  void didUpdateWidget(covariant _FuncBottomNavItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected == oldWidget.selected) return;
    if (MotionTokens.enabled(context)) {
      if (widget.selected) {
        _selection.forward();
      } else {
        _selection.reverse();
      }
    } else {
      _selection.value = widget.selected ? 1 : 0;
    }
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final navTheme = NavigationBarTheme.of(context);
    final states = widget.selected
        ? const <WidgetState>{WidgetState.selected}
        : const <WidgetState>{};
    final iconTheme =
        navTheme.iconTheme?.resolve(states) ?? const IconThemeData();
    final labelStyle = widget.ambientStyle.merge(
      navTheme.labelTextStyle?.resolve(states),
    );
    return Semantics(
      button: true,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _PillInkWell(
            pillKey: _pillKey,
            overlayColor: WidgetStateProperty.resolveWith(
              (inkStates) => _resolveDestinationOverlay(colors, {
                if (widget.selected) WidgetState.selected,
                ...inkStates,
              }),
            ),
            onTap: widget.onTap,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  key: _pillKey,
                  alignment: Alignment.center,
                  children: [
                    NavigationIndicator(
                      animation: _selection,
                      width: FuncBottomNav.indicatorSize.width,
                      height: FuncBottomNav.indicatorSize.height,
                      color: navTheme.indicatorColor,
                      shape: const StadiumBorder(),
                    ),
                    IconTheme.merge(
                      data: iconTheme,
                      child: Icon(widget.destination.icon, size: 24),
                    ),
                  ],
                ),
                const SizedBox(height: FuncSpacing.xs),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FuncBottomNav._labelInset,
                  ),
                  child: FitLabel(
                    widget.destination.label,
                    fit: widget.labelFit,
                    style: labelStyle,
                  ),
                ),
              ],
            ),
          ),
          // A label-only overlay so the merged node reads "推荐，标签 1/5"
          // like a real NavigationBar destination.
          Semantics(
            label: MaterialLocalizations.of(
              context,
            ).tabLabel(tabIndex: widget.index + 1, tabCount: widget.count),
          ),
        ],
      ),
    );
  }
}

/// The destination's tap target: the whole cell takes the pointer, but ink
/// is confined to the pill — the same rect-callback trick the SDK's
/// `_IndicatorInkWell` uses.
class _PillInkWell extends InkResponse {
  const _PillInkWell({
    required this.pillKey,
    super.overlayColor,
    super.onTap,
    super.child,
  }) : super(
         containedInkWell: true,
         highlightColor: Colors.transparent,
         customBorder: const StadiumBorder(),
       );

  final GlobalKey pillKey;

  @override
  RectCallback? getRectCallback(RenderBox referenceBox) {
    return () {
      final pill = pillKey.currentContext!.findRenderObject()! as RenderBox;
      final rect = pill.localToGlobal(Offset.zero) & pill.size;
      return referenceBox.globalToLocal(rect.topLeft) & pill.size;
    };
  }
}

/// The single bottom bar at the home-shell layer: a **sibling** of the
/// branch stack, floating
/// over the pages instead of riding inside one. While the current branch's
/// root route is covered by a pushed route (reported by
/// [BranchRootScaffold] into [branchStackCoveredProvider]) it slides away,
/// as if a whole new screen had been pushed over the home pages.
///
/// It is also the shell's [PromptAnchor]: prompts rest above the height it
/// covers right now, so they ride along as it slides.
class FuncShellBottomNav extends ConsumerStatefulWidget {
  const FuncShellBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.scrollVisibility,
    required this.visibleExtent,
  });

  /// Current branch index.
  final int selectedIndex;

  /// Slot-tap callback — the owning [HomeBranchStack] decides between a
  /// same-branch root reset and a branch switch.
  final ValueChanged<int> onSelected;

  /// 1 = fully shown, 0 = slid entirely below the screen edge. Owned by
  /// [HomeBranchStack], which drives it from scroll deltas bubbling out
  /// of the branch Navigators — the bar floats over the pages, so sliding
  /// never reflows the page underneath.
  final AnimationController scrollVisibility;

  /// Sink for the bar's live covered height at the screen bottom, updated
  /// from the same curved animations that drive the two [SlideTransition]s
  /// below — the Hero landing clip reads it through
  /// [HomeShellChrome.bottomBarVisibleExtent], and it is the bar's prompt
  /// anchor extent.
  final ValueNotifier<double> visibleExtent;

  @override
  ConsumerState<FuncShellBottomNav> createState() => _FuncShellBottomNavState();
}

class _FuncShellBottomNavState extends ConsumerState<FuncShellBottomNav>
    with SingleTickerProviderStateMixin {
  late final AnimationController _coveredVisibility;
  // The same two CurvedAnimation instances the SlideTransitions below use —
  // reading their values here keeps the published extent pixel-exact with
  // the bar's real on-screen position, curves and reverses included.
  late final CurvedAnimation _coveredCurve;
  late CurvedAnimation _scrollCurve;
  double _restingExtent = 0;

  @override
  void initState() {
    super.initState();
    // Durations set in didChangeDependencies.
    _coveredVisibility = AnimationController(
      vsync: this,
      value: ref.read(branchStackCoveredProvider).contains(widget.selectedIndex)
          ? 0
          : 1,
    );
    _coveredCurve = CurvedAnimation(
      parent: _coveredVisibility,
      curve: MotionTokens.navBarShowCurve,
      reverseCurve: MotionTokens.navBarHideCurve,
    )..addListener(_publishVisibleExtent);
    _attachScrollCurve(widget.scrollVisibility);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _coveredVisibility
      ..duration = MotionTokens.resolve(context, MotionTokens.navBarShow)
      ..reverseDuration = MotionTokens.resolve(
        context,
        MotionTokens.navBarHide,
      );
  }

  void _attachScrollCurve(AnimationController controller) {
    _scrollCurve = CurvedAnimation(
      parent: controller,
      curve: MotionTokens.navBarShowCurve,
      reverseCurve: MotionTokens.navBarHideCurve,
    )..addListener(_publishVisibleExtent);
  }

  /// Both slides translate the bar downward by their own fraction of its
  /// height; what is still on screen is the resting extent minus the sum
  /// of the two translations, clamped at zero — the bar cannot hide
  /// further than fully.
  void _publishVisibleExtent() {
    final hidden = (1 - _coveredCurve.value) + (1 - _scrollCurve.value);
    widget.visibleExtent.value = _restingExtent * math.max(0.0, 1.0 - hidden);
  }

  @override
  void didUpdateWidget(covariant FuncShellBottomNav oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      // A hidden bar must return on a branch switch.
      if (MotionTokens.enabled(context)) {
        widget.scrollVisibility.forward();
      } else {
        widget.scrollVisibility.value = 1;
      }
      _syncCovered(_isCovered);
    }
    if (!identical(oldWidget.scrollVisibility, widget.scrollVisibility)) {
      _scrollCurve
        ..removeListener(_publishVisibleExtent)
        ..dispose();
      _attachScrollCurve(widget.scrollVisibility);
    }
  }

  @override
  void dispose() {
    // A rail switch (or shell teardown) unmounts the bar — report zero so
    // the hero clip never reads a stale extent.
    widget.visibleExtent.value = 0;
    _coveredVisibility.dispose();
    _coveredCurve.dispose();
    _scrollCurve.dispose();
    super.dispose();
  }

  bool get _isCovered =>
      ref.read(branchStackCoveredProvider).contains(widget.selectedIndex);

  void _syncCovered(bool covered) {
    if (MotionTokens.enabled(context)) {
      if (covered) {
        _coveredVisibility.reverse();
      } else {
        _coveredVisibility.forward();
      }
    } else {
      _coveredVisibility.value = covered ? 0 : 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Covered state is a provider — watch the slice this bar cares about
    // (is *my* branch covered) so a pushed route inside the branch
    // Navigator rebuilds us and the controller slides away in step.
    // `ref.watch` drives the rebuild declaratively — unlike `ref.listen`,
    // a change that lands between builds can never be dropped.
    final covered = ref.watch(
      branchStackCoveredProvider.select(
        (set) => set.contains(widget.selectedIndex),
      ),
    );
    _syncCovered(covered);
    // The bar is an overlay that *slides* out of the screen —
    // the pages use a full-height layout so nothing reflows underneath.
    // Two stacked transitions: covered (pushed route) over scroll
    // (auto-hide), either one wins the hide.
    _restingExtent = FuncBottomNav.restingExtent(
      MediaQuery.paddingOf(context).bottom,
    );
    // Written during build: safe only because consumers read `.value` per
    // frame or only relayout on it (see HomeShellChrome.bottomBarVisibleExtent
    // and PromptAnchors).
    _publishVisibleExtent();
    return PromptAnchor(
      extent: widget.visibleExtent,
      child: SlideTransition(
        position: _coveredCurve.drive(
          Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero),
        ),
        child: SlideTransition(
          position: _scrollCurve.drive(
            Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero),
          ),
          child: FuncBottomNav(
            destinations: homeDestinations(context),
            selectedIndex: widget.selectedIndex,
            onSelected: widget.onSelected,
          ),
        ),
      ),
    );
  }
}

/// Trailing spacer for branch-root scrollables. The navigation bar floats
/// over the body ([Scaffold.extendBody]), so lists pad their tail by the
/// shell's computed bar extent, available from the first frame. Reports
/// zero on rail layouts, where no bar exists.
class FuncNavBarSpacer extends StatelessWidget {
  const FuncNavBarSpacer({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: HomeShellChrome.maybeOf(context)?.bottomBarExtent ?? 0,
    );
  }
}

/// Marks a context as living on a branch-root page — i.e. underneath the
/// floating shell bottom bar; branch roots read it to handle a re-tap of
/// their own destination. Routes pushed over the branch root are siblings
/// of [BranchRootScaffold], not descendants, so they do not see it.
class BranchRootScope extends InheritedWidget {
  const BranchRootScope({
    super.key,
    required this.branchIndex,
    required super.child,
  });

  final int branchIndex;

  static BranchRootScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BranchRootScope>();

  @override
  bool updateShouldNotify(BranchRootScope oldWidget) =>
      branchIndex != oldWidget.branchIndex;
}

/// Shell for a branch-root page: reports through RouteAware whether the
/// branch's root route is covered by a route pushed inside the branch
/// Navigator, so the shell-level [FuncShellBottomNav] slides away while it
/// is — replacing the physical cover a page-local bar used to get for
/// free.
///
/// `didPushNext`/`didPopNext` fire at push/pop start (RouteObserver
/// notifies synchronously), so the bar animates in step with the route
/// transition rather than after it.
class BranchRootScaffold extends ConsumerStatefulWidget {
  const BranchRootScaffold({
    super.key,
    required this.branchIndex,
    required this.child,
  });

  final int branchIndex;
  final Widget child;

  @override
  ConsumerState<BranchRootScaffold> createState() => _BranchRootScaffoldState();
}

class _BranchRootScaffoldState extends ConsumerState<BranchRootScaffold>
    with RouteAware {
  RouteObserver<ModalRoute<dynamic>>? _observer;
  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = RouteObserverScope.maybeOf(context);
    final route = ModalRoute.of(context);
    if (identical(observer, _observer) && identical(route, _route)) return;
    _unsubscribe();
    _observer = observer;
    _route = route;
    if (observer != null && route != null) {
      observer.subscribe(this, route);
    }
  }

  void _unsubscribe() {
    final observer = _observer;
    final route = _route;
    if (observer != null && route != null) observer.unsubscribe(this);
  }

  /// Fires once on subscribe. A branch stack built in one go — a deep-link
  /// cold start, state restoration — already has routes above the root
  /// then, and no didPushNext ever follows.
  @override
  void didPush() => _recheckCovered();

  @override
  void didPushNext() => _recheckCovered();

  @override
  void didPopNext() => _recheckCovered();

  /// Navigator._updatePages replays synthetic push observations when a
  /// branch rebuild hands the Navigator new pages — didPushNext/didPopNext
  /// fire with no real stack change behind them. Verify a frame later,
  /// once the stack has settled: covered simply means the root route is
  /// no longer the branch Navigator's current route.
  void _recheckCovered() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _setCovered(!(_route?.isCurrent ?? true));
    });
  }

  void _setCovered(bool covered) {
    try {
      ref
          .read(branchStackCoveredProvider.notifier)
          .setCovered(widget.branchIndex, covered);
    } on Object {
      // The provider container can already be gone (test teardown).
    }
  }

  @override
  void dispose() {
    _setCovered(false);
    _unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BranchRootScope(
      branchIndex: widget.branchIndex,
      child: widget.child,
    );
  }
}
