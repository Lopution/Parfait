import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/debug/frame_probe.dart';
import '../../core/platform/app_root_pipeline_owner.dart';
import '../../core/log.dart';
import '../../core/navigation/home_destination.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../layout/app_breakpoints.dart';
import '../layout/form_factor.dart';
import '../motion/motion_tokens.dart';
import '../motion/scroll_hide.dart';
import '../motion/still_work.dart';
import '../motion/swipe_paging.dart';
import '../pull_to_refresh.dart';
import '../navigation/desktop_rail_route.dart';
import '../navigation/forward_history.dart';
import '../navigation/home_shell_metrics.dart';
import '../navigation/route_facade.dart';
import 'func_bottom_nav.dart';
import 'prompt_anchor.dart';
import 'settings/persist_settings.dart';
import 'shell_rail.dart';
import '../window/desktop_command_bar_scope.dart' show DesktopCommandBarScope;

/// Broadcast signal for branch-level re-taps — a tap on the already-selected
/// home destination returns that branch to its root and asks the visible page
/// to scroll to the top.
class ReTapChannel extends ChangeNotifier {
  int _branch = -1;

  int get branch => _branch;

  void emit(int branch) {
    _branch = branch;
    notifyListeners();
  }
}

/// Scrolls an explicit page controller to the top using the app motion gate.
/// A list already at the top refreshes instead (HCI 10), when its
/// [PullToRefresh] was given [controller].
void reTapScrollToTop(BuildContext context, ScrollController controller) {
  if (!controller.hasClients) return;
  if (controller.offset <= 0 && PullToRefresh.trigger(controller)) return;
  final position = controller.position;
  final plan = MotionTokens.scrollToTop(
    position.pixels,
    position.viewportDimension,
  );
  final duration = MotionTokens.resolve(context, plan.duration);
  if (duration == Duration.zero) {
    controller.jumpTo(0);
    return;
  }
  if (plan.start < position.pixels) controller.jumpTo(plan.start);
  controller.animateTo(0, duration: duration, curve: MotionTokens.spatialCurve);
}

/// The home shell container. Branches stay mounted in place so stacks and
/// scroll positions survive switches (`NAV-12`, `NAV-21`), ordered per
/// `homeArrangementProvider` (`NAV-19`). Wide layouts mount [ShellRail]
/// (`NAV-20`); phones allow root-page horizontal branch swipes (`SwipePaging`).
/// Off-screen bar branches mount lazily on still frames (`StillWork`).
class HomeBranchStack extends ConsumerStatefulWidget {
  const HomeBranchStack({
    super.key,
    required this.shell,
    required this.children,
  });

  final StatefulNavigationShell shell;
  final List<Widget> children;

  /// Re-tap events of the enclosing home shell; null outside it.
  static ReTapChannel? reTapOf(BuildContext context) =>
      (context
                  .getElementForInheritedWidgetOfExactType<_HomeBranchScope>()
                  ?.widget
              as _HomeBranchScope?)
          ?.channel;

  @override
  ConsumerState<HomeBranchStack> createState() => _HomeBranchStackState();
}

class _HomeBranchStackState extends ConsumerState<HomeBranchStack>
    with
        TickerProviderStateMixin,
        WidgetsBindingObserver,
        StillWork,
        SwipePaging {
  late final AnimationController _switch = AnimationController(
    vsync: this,
    value: 1,
  );
  late final AnimationController _navVisibility;

  /// Freezes the outgoing branch into one texture while it slides away:
  /// one draw per frame instead of re-rendering the page. The incoming
  /// branch stays live — its ticker, entrances and image fades keep
  /// running so the switch never lands on a frozen page.
  final SnapshotController _switchSnapshot = SnapshotController();

  /// Never armed: assigned to every branch that is not sliding out, so the
  /// `SnapshotWidget` stays in the tree without remounting branches and
  /// only the outgoing one becomes a texture.
  final SnapshotController _idleSnapshot = SnapshotController();

  /// Bumped per switch, so an interrupted switch's completion leaves the
  /// newer one alone.
  int _switchGeneration = 0;
  final ReTapChannel _reTap = ReTapChannel();
  final ValueNotifier<double> _navBarVisibleExtent = ValueNotifier(0);

  /// The rail's width, for prompts to centre beside it.
  final ValueNotifier<double> _railExtent = ValueNotifier(0);
  final HomeShellModalScrim _modalScrim = HomeShellModalScrim();

  /// The rail's open progress: 0 collapsed, 1 expanded. The width it takes
  /// from the branches and the panel it shows follow it every frame.
  late final AnimationController _railOpen = AnimationController(vsync: this);
  double _railOpenTarget = 0;
  bool _railOpenInitialized = false;
  int _current = 0;
  int? _outgoing;

  /// Branches mounted so far.
  final _mounted = <int>{};

  /// The branches on the bar, in its order, as of the last build.
  List<int> _barBranches = const [];
  final _scrollHide = ScrollHideTracker();

  /// How far the bottom bar slides to hide, as of the last build; none on
  /// the rail.
  double _bottomBarExtent = 0;

  /// Where the branches under a swipe are, in places on the bar; null
  /// while no swipe moves them.
  final _swipe = ValueNotifier<double?>(null);

  /// The branch beside the current one that a swipe shows.
  int? _swipePeer;

  /// Whether the last build laid the destinations out on a rail.
  bool _rail = false;

  /// `accessibleNavigation` below TouchExplorationScope: TalkBack is
  /// exploring, not merely some assistive service reading nodes.
  bool _touchExploration = false;

  /// Router delegate listener so desktop rail selection (`收藏`, `下载`, `设置`)
  /// tracks branch 4's active sub-destination without changing `shell.currentIndex`,
  /// and pressing Back from one returns to the originating branch (`NAV-20`).
  GoRouter? _watchedRouter;
  DesktopRailSection _lastRailSection = DesktopRailSection.none;
  int? _returnBranch;
  bool _branch4LeftOnDedicatedSection = false;
  bool _routerRebuildPending = false;

  /// For the write in [dispose], where `ref` is gone.
  late final ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    _current = widget.shell.currentIndex;
    _modalScrim.setActiveBranch(_current);
    _mounted.add(_current);
    scheduleStillWork();
    _navVisibility = AnimationController(vsync: this, value: 1);
    _container = ProviderScope.containerOf(context, listen: false);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden) _rememberDestination();
  }

  /// Saves the destination on screen while the start page is the one used
  /// last. Saved when the app leaves the screen or the shell closes, not
  /// on each switch: a settings write rebuilds the app root. A lost write
  /// only loses that landing: logged, not shown.
  void _rememberDestination() {
    final name = HomeDestination.ofBranch(_current).name;
    final settings = _container.read(settingsProvider).value;
    if (settings == null ||
        settings.homeStartPage != homeStartLastUsed ||
        settings.lastHomeDestination == name) {
      return;
    }
    unawaited(
      _container
          .read(settingsProvider.notifier)
          .setLastHomeDestination(name)
          .catchError((Object error, _) {
            log('home destination not remembered: $error');
          }),
    );
  }

  Duration _switchDuration(BuildContext context, {required bool rail}) =>
      MotionTokens.resolve(
        context,
        rail ? MotionTokens.desktopPageTransition : MotionTokens.branchSwitch,
      );

  DesktopRailSection _computeRailSection(GoRouter? router) {
    if (router == null) return DesktopRailSection.none;
    final meBranch = HomeDestination.me.branchIndex;
    if (_current != meBranch ||
        meBranch >= widget.shell.route.branches.length) {
      return DesktopRailSection.none;
    }
    return desktopRailSectionOfBranch(
      router,
      widget.shell.route.branches[meBranch].navigatorKey,
    );
  }

  void _onRouterChanged() {
    if (!mounted) return;
    final router = _watchedRouter;
    final nextSection = _computeRailSection(router);
    final prevSection = _lastRailSection;
    final meBranch = HomeDestination.me.branchIndex;
    final meTopPath =
        router != null && meBranch < widget.shell.route.branches.length
        ? branchTopUri(
            router,
            widget.shell.route.branches[meBranch].navigatorKey,
          )?.path
        : null;
    if (prevSection != DesktopRailSection.none &&
        nextSection == DesktopRailSection.none &&
        _returnBranch != null &&
        _current == meBranch &&
        meTopPath == '/settings') {
      final target = _returnBranch!;
      _returnBranch = null;
      _lastRailSection = DesktopRailSection.none;
      if (router != null) {
        ForwardHistoryStack.ofRouter(
          router,
        ).suppressOrDiscardForward('settings', locationPrefix: '/settings/');
      }
      scheduleMicrotask(() => mounted ? widget.shell.goBranch(target) : null);
      return;
    }
    if (nextSection != DesktopRailSection.none) {
      _branch4LeftOnDedicatedSection = true;
    } else if (meTopPath == '/settings') {
      _branch4LeftOnDedicatedSection = false;
    }
    if (nextSection == prevSection) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      if (_routerRebuildPending) return;
      _routerRebuildPending = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _routerRebuildPending = false;
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  void _selectHomeDestination(HomeDestination d) {
    if (mounted) _select(d.branchIndex);
  }

  void _attachRouter(GoRouter? next) {
    if (identical(next, _watchedRouter)) return;
    final prev = _watchedRouter;
    if (prev != null) {
      prev.routerDelegate.removeListener(_onRouterChanged);
      ForwardHistoryStack.ofRouter(
        prev,
      ).unregisterHomeDestinationSelector(_selectHomeDestination);
    }
    _watchedRouter = next;
    if (next != null) {
      next.routerDelegate.addListener(_onRouterChanged);
      ForwardHistoryStack.ofRouter(
        next,
      ).registerHomeDestinationSelector(_selectHomeDestination);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachRouter(GoRouter.maybeOf(context));
    final rail = FormFactor.of(
      context,
    ).hasRail(MediaQuery.sizeOf(context).width);
    _switch.duration = _switchDuration(context, rail: rail);
    _navVisibility.duration = MotionTokens.resolve(
      context,
      MotionTokens.chrome,
    );
    _touchExploration = MediaQuery.accessibleNavigationOf(context);
    // Touch exploration started while the bar was scrolled away: bring it
    // back, a TalkBack user cannot find a bar that is off screen.
    if (_touchExploration) _navVisibility.value = 1;
  }

  @override
  void didUpdateWidget(HomeBranchStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = widget.shell.currentIndex;
    if (index == _current) return;
    final previous = _current;
    _dropSwipe();
    _mounted.add(index);
    _outgoing = previous;
    _current = index;
    _modalScrim.setActiveBranch(_current);
    final meBranch = HomeDestination.me.branchIndex;
    if (_current == meBranch &&
        previous != meBranch &&
        DesktopCommandBarScope.isActiveOf(context) &&
        _computeRailSection(_watchedRouter) != DesktopRailSection.none) {
      _returnBranch ??= previous;
      _branch4LeftOnDedicatedSection = true;
    } else if (_current != meBranch) {
      _returnBranch = null;
    }
    final generation = ++_switchGeneration;
    final rail = FormFactor.of(
      context,
    ).hasRail(MediaQuery.sizeOf(context).width);
    final duration = _switchDuration(context, rail: rail);
    if (duration == Duration.zero) {
      _outgoing = null;
      _switchSnapshot.allowSnapshotting = false;
      _switch.value = 1;
      return;
    }
    FrameProbe.instance
      ..enter('branch switch')
      ..mark('branch switch $_outgoing→$index');
    _switchSnapshot.allowSnapshotting = true;
    final releaseSemantics = AppRootPipelineOwner.holdSemantics();
    _switch
      ..duration = duration
      ..forward(from: 0).whenCompleteOrCancel(() {
        releaseSemantics();
        FrameProbe.instance.exit('branch switch');
        if (!mounted || generation != _switchGeneration) return;
        _switchSnapshot.allowSnapshotting = false;
        setState(() => _outgoing = null);
      });
  }

  @override
  void dispose() {
    _attachRouter(null);
    _rememberDestination();
    WidgetsBinding.instance.removeObserver(this);
    _reTap.dispose();
    _swipe.dispose();
    _switch.dispose();
    _switchSnapshot.dispose();
    _idleSnapshot.dispose();
    _navVisibility.dispose();
    _navBarVisibleExtent.dispose();
    _railOpen.dispose();
    _railExtent.dispose();
    _modalScrim.dispose();
    super.dispose();
  }

  @override
  bool runStillWork() {
    for (final branch in _barBranches) {
      if (_mounted.contains(branch) || branch >= widget.children.length) {
        continue;
      }
      setState(() => _mounted.add(branch));
      return true;
    }
    return false;
  }

  void _select(int index) {
    _returnBranch = null;
    final shell = widget.shell;
    final meBranch = HomeDestination.me.branchIndex;
    if (index == meBranch &&
        (_branch4LeftOnDedicatedSection ||
            (shell.currentIndex == meBranch &&
                _lastRailSection != DesktopRailSection.none))) {
      _branch4LeftOnDedicatedSection = false;
      GoRouter.of(context).go('/settings');
      return;
    }
    if (index != shell.currentIndex) {
      shell.goBranch(index);
      return;
    }
    shell.goBranch(index);
    shell.route.branches[index].navigatorKey.currentState?.popUntil(
      (route) =>
          route.isFirst ||
          (route is ModalRoute &&
              route.popDisposition == RoutePopDisposition.doNotPop),
    );
    _reTap.emit(index);
  }

  int get _barPlace => _barBranches.indexOf(_current);

  /// A swipe pages the branches on a phone's bar, from a branch at its
  /// root page, outside touch exploration and a bar tap's switch. A page
  /// still leaving no longer counts for `canPop`, but the root stays
  /// covered, its bar copy on it, until the page has gone.
  bool _swipeAllowed() {
    if (_rail || _touchExploration || _outgoing != null || _barPlace < 0) {
      return false;
    }
    final navigator =
        widget.shell.route.branches[_current].navigatorKey.currentState;
    return navigator != null &&
        !navigator.canPop() &&
        !ref.read(branchStackCoveredProvider).contains(_current);
  }

  /// Whether a page's tabs at their edge hand a swipe to the branches.
  bool _canSwipeTo(bool forward) {
    if (!_swipeAllowed()) return false;
    final place = _barPlace + (forward ? 1 : -1);
    return pageSettling || (place >= 0 && place < _barBranches.length);
  }

  void _dropSwipe() {
    stopPaging();
    _swipe.value = null;
    _swipePeer = null;
  }

  @override
  int get pageCount => _barBranches.length;

  @override
  double get pagePosition => _swipe.value ?? _barPlace.toDouble();

  @override
  void showPagePosition(double position) {
    _swipe.value = position;
    final place = _barPlace;
    final side = position > place
        ? place + 1
        : position < place
        ? place - 1
        : -1;
    final peer = side >= 0 && side < _barBranches.length
        ? _barBranches[side]
        : null;
    if (peer == _swipePeer) return;
    setState(() {
      _swipePeer = peer;
      if (peer != null) _mounted.add(peer);
    });
  }

  @override
  void landOnPage(int page) {
    final target = _barBranches[page];
    _swipe.value = null;
    setState(() {
      _swipePeer = null;
      _current = target;
      _modalScrim.setActiveBranch(_current);
    });
    if (target == widget.shell.currentIndex) return;
    // The bar shows where the swipe went.
    slideChrome(context, _navVisibility, hidden: false);
    widget.shell.goBranch(target);
  }

  /// Slides branch [i] by the swipe, by its place on the bar against the
  /// swipe's position; mirrored for right-to-left bars.
  Widget _swipeSlide(int i, Widget child) {
    final place = _barBranches.indexOf(i);
    final sign = Directionality.of(context) == TextDirection.rtl ? -1.0 : 1.0;
    return ValueListenableBuilder<double?>(
      valueListenable: _swipe,
      builder: (context, position, child) => FractionalTranslation(
        translation: Offset(
          position == null || place < 0 ? 0 : (place - position) * sign,
          0,
        ),
        child: child,
      ),
      child: child,
    );
  }

  bool _onBranchRootScroll(ScrollNotification notification) {
    if (_touchExploration) return false;
    final hide = _scrollHide.update(
      notification,
      _navVisibility,
      travel: _bottomBarExtent,
    );
    if (hide != null) slideChrome(context, _navVisibility, hidden: hide);
    return false;
  }

  /// Where branch [i] slides during a switch: the incoming one in from the
  /// side of its destination on the bar ([order]: the bar's destinations,
  /// then the hidden ones), the outgoing one out the other way. Along the
  /// rail on wide layouts, mirrored for right-to-left bars.
  Animation<Offset> _slideOf(
    int i, {
    required bool rail,
    required List<HomeDestination> order,
  }) {
    final outgoing = _outgoing;
    if (outgoing == null || (i != _current && i != outgoing)) {
      return _still;
    }
    int position(int branch) => order.indexOf(HomeDestination.ofBranch(branch));
    var sign = position(_current) > position(outgoing) ? 1.0 : -1.0;
    if (!rail && Directionality.of(context) == TextDirection.rtl) {
      sign = -sign;
    }
    final away = rail ? Offset(0, 0.03 * sign) : Offset(sign, 0);
    final tween = i == _current
        ? Tween<Offset>(begin: away, end: Offset.zero)
        : Tween<Offset>(begin: Offset.zero, end: -away);
    return _switch.drive(
      tween.chain(CurveTween(curve: MotionTokens.branchSwitchCurve)),
    );
  }

  Animation<double> _fadeOf(int i, {required bool rail}) {
    final outgoing = _outgoing;
    if (!rail || outgoing == null || (i != _current && i != outgoing)) {
      return kAlwaysCompleteAnimation;
    }
    final tween = i == _current
        ? Tween<double>(begin: 0, end: 1)
        : Tween<double>(begin: 1, end: 0);
    return _switch.drive(
      tween.chain(CurveTween(curve: MotionTokens.branchSwitchCurve)),
    );
  }

  void _openDesktopRailSection(
    BuildContext context, {
    required DesktopRailSection target,
    required String location,
  }) {
    final router = GoRouter.of(context);
    final meBranch = HomeDestination.me.branchIndex;
    final currentUri = meBranch < widget.shell.route.branches.length
        ? branchTopUri(
            router,
            widget.shell.route.branches[meBranch].navigatorKey,
          )
        : null;
    if (_current == meBranch &&
        desktopRailSectionForUri(currentUri) == target &&
        currentUri?.toString() == location) {
      return;
    }
    if (_current != meBranch) {
      _returnBranch = _current;
    }
    _branch4LeftOnDedicatedSection = true;
    router.go(location);
  }

  Widget _buildRail(
    BuildContext context,
    List<HomeDestination> shown, {
    required FormFactor form,
    required bool expanded,
    required bool canToggle,
    required bool desktopOwned,
    required DesktopRailSection railSection,
  }) {
    final themeMode = ref.watch(themeModeProvider);
    final nextThemeCode = switch (themeMode) {
      ThemeMode.light => AppSettings.darkTheme,
      ThemeMode.dark => AppSettings.systemTheme,
      ThemeMode.system => AppSettings.lightTheme,
    };
    return ShellRail(
      destinations: homeDestinations(context, shown),
      selectedIndex: homeBarIndexOf(shown, _current),
      onSelected: (index) => _select(shown[index].branchIndex),
      form: form,
      expanded: expanded,
      canToggle: canToggle,
      onToggle: () => unawaited(
        persistSettings(
          context,
          () => ref.read(settingsProvider.notifier).setRailExpanded(!expanded),
        ),
      ),
      onBookmarks: desktopOwned
          ? () => _openDesktopRailSection(
              context,
              target: DesktopRailSection.bookmarks,
              location: '/settings/me?tab=bookmarks',
            )
          : () => unawaited(openMe(context, tab: MeTab.bookmarks)),
      onDownloads: desktopOwned
          ? () => _openDesktopRailSection(
              context,
              target: DesktopRailSection.downloads,
              location: '/settings/downloads',
            )
          : () => unawaited(openDownloadTasks(context)),
      themeMode: themeMode,
      bookmarksSelected:
          desktopOwned && railSection == DesktopRailSection.bookmarks,
      downloadsSelected:
          desktopOwned && railSection == DesktopRailSection.downloads,
      settingsSelected:
          desktopOwned && railSection == DesktopRailSection.settings,
      onToggleTheme: desktopOwned
          ? () => unawaited(
              persistSettings(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .selectTheme(nextThemeCode),
              ),
            )
          : null,
      onSettings: desktopOwned
          ? () => _openDesktopRailSection(
              context,
              target: DesktopRailSection.settings,
              location: '/settings/all',
            )
          : null,
    );
  }

  /// Branch [i] in the stack: on screen while current, sliding out, or
  /// shown beside the current one by a swipe.
  Widget _buildBranch(
    int i, {
    required bool rail,
    required List<HomeDestination> order,
  }) {
    return _swipeSlide(
      i,
      Offstage(
        offstage: i != _current && i != _outgoing && i != _swipePeer,
        // Only the leaving branch freezes: its texture slides in a
        // single draw while the incoming branch runs live — entrances,
        // image fades and press feedback keep animating through the
        // switch instead of jumping at the end.
        child: TickerMode(
          enabled: i == _current || i == _swipePeer,
          // A route on the root navigator (the viewer) pairs its Hero
          // with every branch's top page; only the branch on screen
          // may answer, or an image flew to the same work's card in a
          // branch out of sight (TRANS-07).
          child: HeroMode(
            enabled: i == _current,
            child: FadeTransition(
              opacity: _fadeOf(i, rail: rail),
              child: IgnorePointer(
                ignoring: i != _current,
                // A branch mounting off screen pushes its first route, which
                // would take the focus from the text field on screen.
                child: ExcludeFocus(
                  excluding: i != _current,
                  child: ExcludeSemantics(
                    excluding: i != _current,
                    child: SlideTransition(
                      position: _slideOf(i, rail: rail, order: order),
                      // Always in the tree, so starting a switch never
                      // remounts a branch; only the outgoing branch paints
                      // from a texture.
                      child: SnapshotWidget(
                        // A branch showing a platform view paints live.
                        mode: SnapshotMode.permissive,
                        controller: i == _outgoing
                            ? _switchSnapshot
                            : _idleSnapshot,
                        child: _mounted.contains(i)
                            ? HomeShellBranchScope(
                                branchIndex: i,
                                child: widget.children[i],
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final arrangement = ref.watch(homeArrangementProvider);
    final order = [...arrangement.shown, ...arrangement.hidden];
    _barBranches = [for (final d in arrangement.shown) d.branchIndex];
    final size = MediaQuery.sizeOf(context);
    final width = size.width;
    final height = size.height;
    final form = FormFactor.of(context);
    final rail = _rail = form.hasRail(width);
    final desktopOwned = DesktopCommandBarScope.isActiveOf(context);
    // An immersive page (the novel reader) takes the rail's room too.
    final railShown = rail && !ref.watch(shellRailHiddenProvider);
    final canToggle = form.canToggleRail(width, height: height);
    final railChoice = ref.watch(railExpandedProvider);
    final railSection = _lastRailSection = _computeRailSection(_watchedRouter);
    // Keep wide tablet `Me` and `Settings` locked visually to the compact
    // `74dp` rail (without mutating persisted `railExpandedProvider`) so the
    // 280dp workspace index rail has room. PC keeps the expanded rail (`NAV-20`).
    final collapseForWorkspace =
        form != FormFactor.pc &&
        (_current == HomeDestination.me.branchIndex ||
            railSection == DesktopRailSection.settings) &&
        width >= AppBreakpoints.expanded;
    final expanded = collapseForWorkspace
        ? false
        : form.railExpanded(width, height: height, choice: railChoice);
    // The rail opens and closes by width, not in one frame (MOTION-14):
    // the row it takes from the branches and the panel it reveals move
    // together. The first layout starts at its end value, and an
    // immersive page still takes the room at once.
    final railTarget = expanded ? 1.0 : 0.0;
    final railDuration = MotionTokens.resolve(context, MotionTokens.chrome);
    if (!_railOpenInitialized) {
      _railOpen.value = railTarget;
      _railOpenTarget = railTarget;
      _railOpenInitialized = true;
    } else if (_railOpenTarget != railTarget ||
        (railDuration == Duration.zero && _railOpen.value != railTarget)) {
      _railOpenTarget = railTarget;
      if (railDuration == Duration.zero) {
        // Reduced motion turned on mid-slide lands the rail at once.
        _railOpen.value = railTarget;
      } else {
        FrameProbe.instance
          ..enter('rail switch')
          ..mark('rail switch ${expanded ? 'open' : 'close'}');
        final slide = _railOpen.animateTo(
          railTarget,
          duration: railDuration,
          curve: MotionTokens.chromeCurve,
        );
        slide.whenCompleteOrCancel(
          () => FrameProbe.instance.exit('rail switch'),
        );
        unawaited(slide);
      }
    }
    final bottomBarExtent = _bottomBarExtent = rail
        ? 0.0
        : FuncBottomNav.restingExtent(MediaQuery.paddingOf(context).bottom);
    final branches = Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        SwipePagerScope(
          canPage: _canSwipeTo,
          child: swipeGestures(
            allowsPointer: _swipeAllowed,
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (var i = 0; i < widget.children.length; i++)
                  _buildBranch(i, rail: rail, order: order),
              ],
            ),
          ),
        ),
        if (!rail)
          Align(
            alignment: Alignment.bottomCenter,
            child: FuncShellBottomNav(
              destinations: arrangement.shown,
              currentBranch: _current,
              onSelected: _select,
              scrollVisibility: _navVisibility,
              visibleExtent: _navBarVisibleExtent,
            ),
          ),
      ],
    );
    final strip = NotificationListener<ScrollNotification>(
      onNotification: trackStillScroll,
      child: branches,
    );
    return AnimatedBuilder(
      animation: _railOpen,
      builder: (context, _) {
        final railWidth = railShown
            ? ShellRail.width +
                  (ShellRail.expandedWidth - ShellRail.width) * _railOpen.value
            : 0.0;
        _railExtent.value = railWidth;
        return HomeShellChrome(
          bottomBarExtent: bottomBarExtent,
          railExtent: railWidth,
          bottomBarVisibleExtent: _navBarVisibleExtent,
          bottomBarVisibility: _navVisibility,
          onBranchRootScroll: _onBranchRootScroll,
          modalScrim: _modalScrim,
          child: _HomeBranchScope(
            channel: _reTap,
            // The rail lies over the branches' edge so its shadow falls on
            // them; the branches keep their place in the tree whether the rail
            // shows or not (NAV-21).
            child: rail
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Padding(
                        padding: EdgeInsetsDirectional.only(start: railWidth),
                        child: strip,
                      ),
                      if (railShown)
                        PositionedDirectional(
                          start: 0,
                          top: 0,
                          bottom: 0,
                          width: railWidth,
                          child: PromptAnchor(
                            extent: _railExtent,
                            edge: PromptAnchorEdge.start,
                            child: _buildRail(
                              context,
                              arrangement.shown,
                              form: form,
                              expanded: expanded,
                              canToggle: canToggle,
                              desktopOwned: desktopOwned,
                              railSection: railSection,
                            ),
                          ),
                        ),
                      if (railShown)
                        HomeRailModalScrim(
                          scrim: _modalScrim,
                          railWidth: railWidth,
                        ),
                    ],
                  )
                : strip,
          ),
        );
      },
    );
  }
}

const _still = AlwaysStoppedAnimation<Offset>(Offset.zero);

class _HomeBranchScope extends InheritedWidget {
  const _HomeBranchScope({required this.channel, required super.child});

  final ReTapChannel channel;

  @override
  bool updateShouldNotify(_HomeBranchScope oldWidget) =>
      channel != oldWidget.channel;
}
