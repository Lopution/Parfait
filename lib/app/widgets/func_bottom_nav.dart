import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/navigation/route_observer.dart';
import '../../l10n/context.dart';
import '../motion/motion_tokens.dart';
import '../motion/scroll_hide.dart';
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
/// branch stack, floating over the pages instead of riding inside one, so
/// it stays put while the branches slide past under it.
///
/// While the current branch's root is covered (reported by
/// [BranchRootScaffold] into [branchStackCoveredProvider]) it steps aside
/// and the root page draws the same bar underneath the covering routes —
/// pages pushed inside the branch cover the bar the way a new screen
/// would.
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
  /// [HomeBranchStack], which drives it from the current branch root's
  /// scrolling — the bar floats over the pages, so sliding never reflows
  /// the page underneath.
  final AnimationController scrollVisibility;

  /// Sink for the bar's live covered height at the screen bottom — the
  /// Hero landing clip reads it through
  /// [HomeShellChrome.bottomBarVisibleExtent], and it is the bar's prompt
  /// anchor extent.
  final ValueNotifier<double> visibleExtent;

  @override
  ConsumerState<FuncShellBottomNav> createState() => _FuncShellBottomNavState();
}

class _FuncShellBottomNavState extends ConsumerState<FuncShellBottomNav> {
  double _restingExtent = 0;

  @override
  void initState() {
    super.initState();
    widget.scrollVisibility.addListener(_publishVisibleExtent);
  }

  /// What is still on screen of the bar as it slides.
  void _publishVisibleExtent() {
    widget.visibleExtent.value =
        _restingExtent * ScrollHiddenChrome.shownOf(widget.scrollVisibility);
  }

  @override
  void didUpdateWidget(covariant FuncShellBottomNav oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.scrollVisibility, widget.scrollVisibility)) {
      oldWidget.scrollVisibility.removeListener(_publishVisibleExtent);
      widget.scrollVisibility.addListener(_publishVisibleExtent);
    }
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      // A hidden bar must return on a branch switch.
      slideChrome(context, widget.scrollVisibility, hidden: false);
    }
  }

  @override
  void dispose() {
    widget.scrollVisibility.removeListener(_publishVisibleExtent);
    // A rail switch (or shell teardown) unmounts the bar — report zero so
    // the hero clip never reads a stale extent.
    widget.visibleExtent.value = 0;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch only the slice this bar cares about: is *my* branch covered.
    final covered = ref.watch(
      branchStackCoveredProvider.select(
        (set) => set.contains(widget.selectedIndex),
      ),
    );
    _restingExtent = FuncBottomNav.restingExtent(
      MediaQuery.paddingOf(context).bottom,
    );
    // Written during build: safe only because consumers read `.value` per
    // frame or only relayout on it (see HomeShellChrome.bottomBarVisibleExtent
    // and PromptAnchors).
    _publishVisibleExtent();
    // Covered, the root page's copy of the bar anchors prompts: it sinks
    // with the root as pages cover it.
    return PromptAnchor(
      extent: covered ? _noExtent : widget.visibleExtent,
      child: Offstage(
        offstage: covered,
        child: ScrollHiddenChrome(
          visibility: widget.scrollVisibility,
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

const _noExtent = AlwaysStoppedAnimation<double>(0);

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

/// Shell for a branch-root page. It hands the user's scrolling of the page
/// to the shell bar ([HomeShellChrome.onBranchRootScroll]) and reports
/// whether the root route is covered into [branchStackCoveredProvider].
///
/// Covered — a route sits on the root inside the branch Navigator, or a
/// page transition over it has not settled — the shell bar steps aside and
/// this scaffold draws an inert copy of it at the same place, so the
/// routes above cover the bar like any other part of the page and it
/// leaves and returns with the page. The swap happens while the two copies
/// overlap exactly: as a push starts and once a pop has fully revealed the
/// root.
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
  Animation<double>? _cover;
  bool _covered = false;
  bool _syncScheduled = false;

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
    _cover = route?.secondaryAnimation?..addStatusListener(_onCoverStatus);
  }

  void _unsubscribe() {
    if (_observer != null && _route != null) _observer!.unsubscribe(this);
    _cover?.removeStatusListener(_onCoverStatus);
  }

  /// Fires once on subscribe. A branch stack built in one go — a deep-link
  /// cold start, state restoration — already has routes above the root
  /// then, and no didPushNext ever follows.
  @override
  void didPush() => _scheduleSync();

  /// RouteObserver notifies at push and pop start.
  @override
  void didPushNext() => _scheduleSync();

  @override
  void didPopNext() => _scheduleSync();

  /// A transition over the root starts, settles, or finishes revealing it.
  void _onCoverStatus(AnimationStatus status) => _scheduleSync();

  /// Navigator._updatePages notifies while the tree builds — and replays
  /// synthetic push observations with no real stack change behind them.
  /// Neither the provider nor this state may change mid-build, so those
  /// wait for the frame's end and read the settled stack then.
  void _scheduleSync() {
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      _sync();
      return;
    }
    if (_syncScheduled) return;
    _syncScheduled = true;
    scheduler.addPostFrameCallback((_) {
      _syncScheduled = false;
      _sync();
    });
  }

  void _sync() {
    if (!mounted) return;
    final route = _route;
    final covered =
        route != null &&
        (!route.isCurrent || !(route.secondaryAnimation?.isDismissed ?? true));
    _setCovered(covered);
    if (covered != _covered) setState(() => _covered = covered);
  }

  void _setCovered(bool covered) {
    try {
      ref
          .read(branchStackCoveredProvider.notifier)
          .setCovered(this, widget.branchIndex, covered);
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
    final chrome = HomeShellChrome.maybeOf(context);
    final page = BranchRootScope(
      branchIndex: widget.branchIndex,
      child: chrome == null
          ? widget.child
          : NotificationListener<ScrollNotification>(
              onNotification: chrome.onBranchRootScroll,
              child: widget.child,
            ),
    );
    final bar = chrome == null || chrome.bottomBarExtent == 0 ? null : chrome;
    // The Stack stays whether or not the copy shows, so the page below is
    // never remounted.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        page,
        if (bar != null && _covered)
          Align(
            alignment: Alignment.bottomCenter,
            child: PromptAnchor(
              extent: bar.bottomBarVisibleExtent,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: ScrollHiddenChrome(
                    visibility: bar.bottomBarVisibility,
                    child: FuncBottomNav(
                      destinations: homeDestinations(context),
                      selectedIndex: widget.branchIndex,
                      onSelected: _ignoreSelection,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

void _ignoreSelection(int _) {}
