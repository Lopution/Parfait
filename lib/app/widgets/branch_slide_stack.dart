import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/context.dart';
import '../icons/app_icons.dart';
import '../layout/app_breakpoints.dart';
import '../motion/motion_tokens.dart';
import 'func_bottom_nav.dart';
import 'root_swipe_switcher.dart';

/// Continuous driver for the branch strip — the outer half of the
/// nested-pager pair [RootSwipeSwitcher] completes. It wraps a real
/// [TabController] so the bottom branches track the finger through exactly
/// the same `offset`/`animation`/`animateTo` machinery the top tab strips
/// use: half-page warps, release settle and indicator sync are shared
/// behaviour, not a second position model.
///
/// Index changes forward to `goBranch` (ViewPager `onPageSelected` parity:
/// the branch commits the moment the drag crosses the midpoint), while
/// external moves — deep links, restoration — land through [syncIndex],
/// which suppresses that callback so a deep link into a covered branch
/// never pops the pushed route. Chrome taps (bottom bar, NavigationRail)
/// are not external: both controls funnel into [selectIndex].
class BranchSlidePager extends ChangeNotifier {
  BranchSlidePager({
    required TickerProvider vsync,
    required int count,
    required int initialIndex,
    required bool Function() motionEnabled,
  }) : _vsync = vsync,
       _motionEnabled = motionEnabled,
       _lastIndex = initialIndex,
       tab = TabController(
         length: count,
         vsync: vsync,
         initialIndex: initialIndex,
       ) {
    tab.addListener(_onTabChanged);
  }

  /// Branch positions are shell branch indices directly — the bottom bar
  /// renders its destinations in branch order, so no slot remap exists.
  final TabController tab;

  /// Branch-level re-tap broadcast — see [ReTapChannel] for the frozen
  /// contract W3 pages consume.
  final ReTapChannel reTapEvents = ReTapChannel();

  final TickerProvider _vsync;
  final bool Function() _motionEnabled;
  StatefulNavigationShell? _shell;
  int _lastIndex;
  bool _suppressGoBranch = false;
  bool _dragging = false;
  double _dragOrigin = 0;
  AnimationController? _settle;
  Animation<double>? _settleAnim;
  int _settleTarget = 0;

  /// Live strip position in pages — the continuous `animation.value`, safe
  /// to read mid-warp (unlike `index + offset` recompositions).
  double get position => tab.animation?.value ?? tab.index.toDouble();

  int get count => tab.length;

  void attach(StatefulNavigationShell shell) => _shell = shell;

  void _onTabChanged() {
    if (tab.index == _lastIndex) return;
    _lastIndex = tab.index;
    // Bars listen on this notifier for the selected-index repaint.
    notifyListeners();
    if (_suppressGoBranch) return;
    _shell?.goBranch(tab.index);
  }

  /// A finger is down. A grab mid-`animateTo` inherits the in-flight
  /// position: pin the index so `offset` (which asserts !indexIsChanging)
  /// stays writable.
  void beginDrag() {
    _dragging = true;
    _settle?.stop();
    if (tab.indexIsChanging) {
      tab.index = (tab.animation?.value ?? tab.index.toDouble()).round().clamp(
        0,
        count - 1,
      );
    }
    _dragOrigin = position;
  }

  /// Live-follow drag, in pages. Hard clamp at the outermost branch — a
  /// ViewPager edge stops dead; there is no rubber-band.
  void dragBy(double pageDelta) {
    // A programmatic move (selectIndex) clears _dragging without lifting
    // the finger — deltas after that point must not write offset, or the
    // release will skip endDrag and leave the strip parked mid-slide.
    if (!_dragging || count == 0 || tab.indexIsChanging) return;
    final max = count - 1.0;
    final target = (position + pageDelta).clamp(0.0, max);
    // Midpoint warp keeps `offset` inside its [-1, 1] contract and hops the
    // branch listener (→ goBranch) the instant the drag commits visually.
    if ((target - tab.index).abs() > 0.5) {
      tab.index = target.round().clamp(0, count - 1);
    }
    tab.offset = (target - tab.index).clamp(-1.0, 1.0);
  }

  /// Release. [vPages] is the fling velocity in pages/s (positive =
  /// advancing); [flingPages] is the commit threshold in the same unit —
  /// the switcher passes its px/s constant converted by screen width so
  /// the cutover matches the strip's own bar exactly. Same contract as
  /// the top strip: a committed fling or a quarter-page displacement
  /// switches; anything less reels back in.
  void endDrag(double vPages, {double flingPages = 1.0}) {
    // Defensive: a release/cancel without a matching beginDrag carries a
    // stale _dragOrigin and must not pass judgement on the strip.
    if (!_dragging || count == 0 || _shell == null) return;
    _dragging = false;
    final base = _dragOrigin.round().clamp(0, count - 1);
    final moved = position - base;
    final fling = vPages.abs() >= flingPages;
    final committed =
        fling || moved.abs() >= RootSwipeSwitcher.distanceFraction;
    // Velocity wins when a flick reverses across the distance the finger
    // already covered — ViewPager reads the release velocity the same way.
    final forward = fling ? vPages > 0 : moved > 0;
    final target = (committed ? base + (forward ? 1 : -1) : base).clamp(
      0,
      count - 1,
    );
    if (target == tab.index) {
      // A mid-drag warp may have already hopped index onto the target —
      // `animateTo` would early-return, so reel `offset` in by hand.
      _settleTo(target);
      return;
    }
    tab.animateTo(target, duration: _motionEnabled() ? null : Duration.zero);
  }

  /// Chrome tap — the single action entry the bottom bar and the
  /// NavigationRail share. A same-destination tap is the re-tap gesture:
  /// the branch stack returns to its root and [reTapEvents] fires so the
  /// revealed root page can scroll to top. Other slots slide over like
  /// Shaft's `viewPager.setCurrentItem` (smooth scroll).
  void selectIndex(int index) {
    final shell = _shell;
    if (shell == null) return;
    if (index == tab.index) {
      // goBranch restores the branch's stored match list — for the
      // current branch that IS the live location (pushed routes included),
      // so the call itself is a no-op. The branch Navigator's stack is
      // popped to its root route explicitly. A vetoed route (PopScope
      // canPop:false → doNotPop) stops the pop: pop() on it never removes
      // the route and popUntil would loop forever, so the predicate must
      // cut the pop short — the tick still fires and lands on a covered
      // root page, which consumers must tolerate.
      shell.goBranch(index);
      shell.route.branches[index].navigatorKey.currentState?.popUntil(
        (route) =>
            route.isFirst ||
            (route is ModalRoute &&
                route.popDisposition == RoutePopDisposition.doNotPop),
      );
      reTapEvents.emit(index);
      return;
    }
    // A programmatic move wins over an in-flight drag: clear the gesture
    // bookkeeping so the release (when the finger lifts) no-ops instead
    // of judging the strip from a stale drag origin, and stop a settle
    // whose offset ticks would fight the animateTo flight.
    _dragging = false;
    _settle?.stop();
    tab.animateTo(index, duration: _motionEnabled() ? null : Duration.zero);
  }

  /// The shell's index moved outside a drag (deep link, restoration):
  /// slide the strip to wherever it landed — without re-entering
  /// goBranch, which would navigateToRoot and drop a pushed route.
  void syncIndex() {
    if (_dragging || count == 0) return;
    final shell = _shell;
    if (shell == null) return;
    final index = shell.currentIndex.clamp(0, count - 1);
    if (tab.index == index && position == index.toDouble()) return;
    _suppressGoBranch = true;
    try {
      if (tab.index != index) {
        tab.animateTo(index, duration: _motionEnabled() ? null : Duration.zero);
      } else {
        _settleTo(index);
      }
    } finally {
      _suppressGoBranch = false;
    }
  }

  /// Hand-rolled reel-in for targets `animateTo` refuses (same index after
  /// a warp): each tick writes `animation.value` back through `offset`.
  void _settleTo(int target) {
    _settleTarget = target;
    final from = position;
    if (!_motionEnabled() || (from - target).abs() < 1e-4) {
      tab.index = target;
      tab.offset = 0;
      return;
    }
    final controller = _settle ??= AnimationController(vsync: _vsync)
      ..addListener(_applySettle)
      ..addStatusListener(_finishSettle);
    controller.duration = MotionTokens.fast;
    _settleAnim = Tween<double>(begin: from, end: target.toDouble()).animate(
      CurvedAnimation(parent: controller, curve: MotionTokens.fastCurve),
    );
    controller.forward(from: 0);
  }

  void _applySettle() {
    final anim = _settleAnim;
    if (anim == null || tab.indexIsChanging) return;
    tab.offset = (anim.value - tab.index).clamp(-1.0, 1.0);
  }

  void _finishSettle(AnimationStatus status) {
    if (status != AnimationStatus.completed || tab.indexIsChanging) return;
    tab.index = _settleTarget;
    tab.offset = 0;
  }

  @override
  void dispose() {
    reTapEvents.dispose();
    _settle?.dispose();
    tab.dispose();
    super.dispose();
  }
}

/// Broadcast signal for branch-level re-taps — a tap on the bottom bar's
/// already-selected destination (Shaft/iOS "return to root, scroll to
/// top" parity; PixEz `topStore` is the same shape).
///
/// Frozen contract — W3 pages consume this channel, do not fork it or
/// change the payload semantics:
/// * Emitted ONLY from [BranchSlidePager.selectIndex] on the
///   `index == tab.index` path — an explicit same-destination tap — after
///   the branch Navigator has been popped back toward its root route.
/// * Never emitted from `syncIndex`, drag settles, or any
///   `_suppressGoBranch` path: programmatic moves are not re-taps.
/// * Fires on every tap, including repeats on the same branch — the event
///   is an edge, not a state (a `ValueNotifier<int>` would swallow
///   consecutive same-index taps).
/// * Consumers `addListener`, read [branch], and — in a post-frame
///   callback, after the pop commits and the root page is visible again —
///   scroll the *visible* scrollable's explicit `ScrollController` to the
///   top via [reTapScrollToTop]. Pure scroll: no refresh, no selector
///   expand/collapse, no selection change.
class ReTapChannel extends ChangeNotifier {
  int _branch = -1;

  /// The branch index of the most recent re-tap; -1 before the first one.
  int get branch => _branch;

  void emit(int branch) {
    _branch = branch;
    notifyListeners();
  }
}

/// The shared consumer half of the re-tap contract: scroll [controller]
/// to offset 0, motion-gated by `MotionTokens` — reduced motion jumps
/// instead of animating. Used by both channel subscribers (branch-level
/// re-tap) and in-page same-index selector taps (`TabBar.onTap`/chips).
///
/// Callers must pass the scrollable's explicit `ScrollController` — on
/// desktop `SmoothWheelScroll` owns a private controller that
/// `PrimaryScrollController.of` cannot reach.
void reTapScrollToTop(BuildContext context, ScrollController controller) {
  if (!controller.hasClients) return;
  final duration = MotionTokens.resolve(context, MotionTokens.fast);
  if (duration == Duration.zero) {
    controller.jumpTo(0);
  } else {
    controller.animateTo(0, duration: duration, curve: MotionTokens.fastCurve);
  }
}

/// Drop-in for `StatefulShellRoute.indexedStack`'s container, rebuilt as
/// Shaft's `activity_cover.xml`: the branch Navigators are the ViewPager
/// pages laid out side by side, and the navigation chrome is their
/// **sibling** — the bottom bar floats over the strip and never moves
/// with the page underneath; on wide surfaces a NavigationRail sits to
/// the side instead. Both controls are the same gesture source: taps
/// reach [BranchSlidePager.selectIndex], so a same-destination rail tap
/// re-taps exactly like the bar's.
///
/// Offstage keeps every branch alive (same contract as IndexedStack); only
/// the one-page window around the current position lays out. The scroll-hide
/// behaviour lives here too: vertical ScrollNotifications bubble out of the
/// branch Navigators into one listener that slides the bar — the same
/// HideViewOnScroll scheme [BranchRootScaffold] used to run per page.
class BranchSlideStack extends StatefulWidget {
  const BranchSlideStack({
    super.key,
    required this.shell,
    required this.children,
  });

  final StatefulNavigationShell shell;
  final List<Widget> children;

  /// The pager driving this container, visible to the [RootSwipeSwitcher]s
  /// inside each branch's root page.
  static BranchSlidePager? maybeOf(BuildContext context) =>
      (context
                  .getElementForInheritedWidgetOfExactType<_BranchSlideScope>()
                  ?.widget
              as _BranchSlideScope?)
          ?.pager;

  @override
  State<BranchSlideStack> createState() => _BranchSlideStackState();
}

class _BranchSlideStackState extends State<BranchSlideStack>
    with TickerProviderStateMixin {
  late final BranchSlidePager _pager = BranchSlidePager(
    vsync: this,
    count: widget.children.length,
    initialIndex: widget.shell.currentIndex,
    motionEnabled: () => mounted && MotionTokens.enabled(context),
  );
  late final AnimationController _navVisibility;
  double _scrollAccum = 0;
  double? _lastPixels;
  BuildContext? _lastScrollable;

  @override
  void initState() {
    super.initState();
    _pager.attach(widget.shell);
    _navVisibility = AnimationController(
      vsync: this,
      duration: MotionTokens.navBarShow,
      reverseDuration: MotionTokens.navBarHide,
      value: 1,
    );
  }

  @override
  void didUpdateWidget(BranchSlideStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pager.attach(widget.shell);
    _pager.syncIndex();
  }

  @override
  void dispose() {
    _pager.dispose();
    _navVisibility.dispose();
    super.dispose();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    // Only the viewport that originated the scroll — a nested vertical
    // scrollable's notification bubbles through here too (depth > 0) and
    // would double-count the same finger travel.
    if (notification.depth != 0) return false;
    if (notification.metrics.axis != Axis.vertical) return false;
    // Track the *clamped* pixel position per scrollable instead of trusting
    // `scrollDelta`: a single drag can cross an edge (real content scroll
    // for the first leg, overscroll for the rest) and `outOfRange` only
    // describes the landing state — the real leg must still count, while
    // spring-back replays must not. RecyclerView's `dy` in Shaft's
    // BottomBarAutoHide has exactly this semantics.
    final metrics = notification.metrics;
    if (!metrics.hasContentDimensions) return false;
    if (!identical(notification.context, _lastScrollable)) {
      _lastScrollable = notification.context;
      _lastPixels = null;
      _scrollAccum = 0;
    }
    final clamped = metrics.pixels.clamp(
      metrics.minScrollExtent,
      metrics.maxScrollExtent,
    );
    final last = _lastPixels;
    _lastPixels = clamped;
    if (notification is! ScrollUpdateNotification || last == null) {
      return false;
    }
    final delta = clamped - last;
    if (delta == 0) return false;
    // Same sign keeps accumulating; a reversal restarts from the fresh
    // delta so a short reverse flick does not have to pay off a long run.
    _scrollAccum = (_scrollAccum * delta < 0) ? delta : _scrollAccum + delta;
    // Shaft's BottomBarAutoHide gates on ViewConfiguration.scaledTouchSlop —
    // the platform's real slop (~8dp), not kTouchSlop (18). Anything higher
    // makes the bar feel unresponsive to short flicks.
    final slop = MediaQuery.maybeGestureSettingsOf(context)?.touchSlop ?? 8.0;
    // Reset after firing like BottomBarAutoHide does — otherwise the
    // accumulator grows unbounded during a long scroll in one direction.
    if (_scrollAccum > slop) {
      _setNavHidden(true);
      _scrollAccum = 0;
    } else if (_scrollAccum < -slop) {
      _setNavHidden(false);
      _scrollAccum = 0;
    }
    return false;
  }

  void _setNavHidden(bool hidden) {
    if (MotionTokens.enabled(context)) {
      if (hidden) {
        _navVisibility.reverse();
      } else {
        _navVisibility.forward();
      }
    } else {
      _navVisibility.value = hidden ? 0 : 1;
    }
  }

  /// Stand-in Navigators for branches the shell has not loaded yet, built
  /// only while a drag actually pulls their slot into the window. Same
  /// `navigatorKey` as the real branch: when `goBranch` lands, the proxy's
  /// Navigator reparents this state — scroll, stack and all — so the
  /// hand-off is invisible.
  final Map<int, Widget> _fallbackNavigators = {};

  /// Branches the shell has built a Navigator for. The public signal is
  /// "has been the current index": `goBranch`/init always builds the
  /// current branch before the container sees it, and once built the
  /// proxy keeps the Navigator alive for the shell's lifetime.
  final Set<int> _visitedBranches = {};

  Widget _branchChild(int index, {required bool offscreen}) {
    if (_visitedBranches.contains(index)) {
      _fallbackNavigators.remove(index);
      return widget.children[index];
    }
    // A fallback once built stays mounted — letting it slip back to the
    // empty proxy on an edge bounce would dispose its NavigatorState and
    // flash a blank page on the next drag-in.
    final cached = _fallbackNavigators[index];
    if (cached != null) return cached;
    if (offscreen) return widget.children[index];
    return _fallbackNavigators[index] =
        _buildFallbackNavigator(index) ?? widget.children[index];
  }

  /// Mirrors `StatefulNavigationShellState._preloadBranches`: find the
  /// shell match inside the branch's initial-location match list, then let
  /// the shell's own navigatorBuilder produce the exact same Navigator
  /// widget it would have built on first visit.
  Widget? _buildFallbackNavigator(int branchIndex) {
    final shell = widget.shell;
    final branch = shell.route.branches[branchIndex];
    final location = branch.initialLocation ?? branch.defaultRoute?.path;
    if (location == null || !location.startsWith('/')) return null;
    final matchList = GoRouter.of(
      context,
    ).configuration.findMatch(Uri.parse(location));
    ShellRouteMatch? match;
    for (final RouteMatchBase m in matchList.matches) {
      if (m is ShellRouteMatch && m.route == shell.route) {
        match = m;
        break;
      }
    }
    if (match == null) return null;
    return shell.shellRouteContext.navigatorBuilder(
      branch.navigatorKey,
      match,
      matchList,
      branch.observers,
      branch.restorationScopeId,
    );
  }

  /// The wide-surface rail — the bottom bar's peer, fed by the same
  /// [_pager]. `selectedIndex` listens on the pager so the highlight hops
  /// at the drag midpoint in step with the bar, and every tap lands on
  /// [BranchSlidePager.selectIndex]: same index re-taps (pop to root +
  /// scroll to top), different index slides over.
  Widget _buildRail(BuildContext context) {
    // Three chrome tiers on the same width ladder: bottom bar (<600),
    // compact rail (600-1199), labelled extended rail (>=1200). The rail
    // animates the extended transition itself, so a window resize across
    // the boundary swaps forms without a flash.
    final extended = AppBreakpoints.useExtendedRail(
      MediaQuery.sizeOf(context).width,
    );
    final labels = [
      context.l10n.homeRecommended,
      context.l10n.homeRanking,
      context.l10n.newTitle,
      context.l10n.searchTitle,
      context.l10n.settingsTitle,
    ];
    return ListenableBuilder(
      listenable: _pager,
      builder: (context, _) => NavigationRail(
        selectedIndex: _pager.tab.index,
        onDestinationSelected: _pager.selectIndex,
        extended: extended,
        // `extended` requires labelType null/none; the compact rail keeps
        // labels under every icon.
        labelType: extended ? null : NavigationRailLabelType.all,
        destinations: [
          for (var i = 0; i < _railIcons.length; i++)
            NavigationRailDestination(
              icon: Icon(_railIcons[i], size: 26),
              label: Text(labels[i]),
            ),
        ],
      ),
    );
  }

  static const _railIcons = [
    AppIcons.home,
    AppIcons.ranking,
    AppIcons.n,
    AppIcons.search,
    Icons.settings_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // The shell always builds the current branch's Navigator — mark it
    // before the layout pass so the proxy path owns it.
    _visitedBranches.add(widget.shell.currentIndex);
    final rail = AppBreakpoints.useNavigationRail(
      MediaQuery.sizeOf(context).width,
    );
    final strip = NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          AnimatedBuilder(
            animation: _pager.tab.animation ?? _pager.tab,
            builder: (context, _) {
              final pos = _pager.position;
              return Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.hardEdge,
                children: [
                  for (var i = 0; i < widget.children.length; i++)
                    // IndexedStack only publishes the current child's
                    // semantics; match that — a slot more than half a
                    // page out is not the screen the user is looking at.
                    ExcludeSemantics(
                      excluding: (i - pos).abs() > 0.5,
                      child: Offstage(
                        // `>=` not `>`: at rest the neighbour sits
                        // exactly one page out — fully offscreen — so it
                        // stays offstage and out of hit tests/finders
                        // until a drag pulls pos off the integer and it
                        // genuinely enters the window.
                        offstage: (i - pos).abs() >= 1.0,
                        child: FractionalTranslation(
                          translation: Offset(rtl ? pos - i : i - pos, 0),
                          // An offscreen slot keeps the bare proxy —
                          // unvisited branches stay unbuilt (the
                          // cold-start contract); the stand-in Navigator
                          // is only built once the slot genuinely
                          // enters the window.
                          child: _branchChild(
                            i,
                            offscreen: (i - pos).abs() >= 1.0,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          // The bar is the ViewPager's sibling, not a child of a page —
          // it never translates with the strip underneath.
          if (!rail)
            Align(
              alignment: Alignment.bottomCenter,
              child: ListenableBuilder(
                listenable: _pager,
                builder: (context, _) => FuncShellBottomNav(
                  selectedIndex: _pager.tab.index,
                  onSelected: _pager.selectIndex,
                  scrollVisibility: _navVisibility,
                  indicatorAnimation:
                      _pager.tab.animation ??
                      AlwaysStoppedAnimation(_pager.position),
                ),
              ),
            ),
        ],
      ),
    );
    return _BranchSlideScope(
      pager: _pager,
      child: rail
          ? Row(
              children: [
                _buildRail(context),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(child: strip),
              ],
            )
          : strip,
    );
  }
}

class _BranchSlideScope extends InheritedWidget {
  const _BranchSlideScope({required this.pager, required super.child});

  final BranchSlidePager pager;

  @override
  bool updateShouldNotify(_BranchSlideScope oldWidget) =>
      pager != oldWidget.pager;
}
