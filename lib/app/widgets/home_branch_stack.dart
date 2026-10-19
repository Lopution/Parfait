import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/debug/frame_probe.dart';
import '../../core/platform/app_root_pipeline_owner.dart';
import '../../core/log.dart';
import '../../core/navigation/home_destination.dart';
import '../../core/settings/settings_controller.dart';
import '../layout/app_breakpoints.dart';
import '../motion/motion_tokens.dart';
import '../motion/scroll_hide.dart';
import '../motion/still_work.dart';
import '../pull_to_refresh.dart';
import '../navigation/home_shell_metrics.dart';
import 'func_bottom_nav.dart';

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

/// The home shell container. Branches remain mounted in place so each branch
/// retains its navigator stack and scroll state; a switch slides the
/// outgoing and incoming branch side by side, toward where the chosen
/// destination sits on the bar. The bar and rail show the user's
/// destinations in their order.
///
/// The branch on screen mounts at once; the other destinations on the bar
/// mount one at a time on a still screen ([StillWork]), so a first switch
/// to one does not build its whole page inside the switch. A mounted
/// branch stays mounted. The router preloads every branch only to hand
/// over its Navigator: it builds a page once mounted here.
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
    with TickerProviderStateMixin, WidgetsBindingObserver, StillWork {
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
  int _current = 0;
  int? _outgoing;

  /// Branches mounted so far.
  final _mounted = <int>{};

  /// The branches on the bar, in its order, as of the last build.
  List<int> _barBranches = const [];
  final _scrollHide = ScrollHideTracker();

  /// `accessibleNavigation` below TouchExplorationScope: TalkBack is
  /// exploring, not merely some assistive service reading nodes.
  bool _touchExploration = false;

  /// For the write in [dispose], where `ref` is gone.
  late final ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    _current = widget.shell.currentIndex;
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _switch.duration = MotionTokens.resolve(context, MotionTokens.branchSwitch);
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
    _mounted.add(index);
    _outgoing = _current;
    _current = index;
    final generation = ++_switchGeneration;
    final duration = MotionTokens.resolve(context, MotionTokens.branchSwitch);
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
    _rememberDestination();
    WidgetsBinding.instance.removeObserver(this);
    _reTap.dispose();
    _switch.dispose();
    _switchSnapshot.dispose();
    _idleSnapshot.dispose();
    _navVisibility.dispose();
    _navBarVisibleExtent.dispose();
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
    final shell = widget.shell;
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

  bool _onBranchRootScroll(ScrollNotification notification) {
    if (_touchExploration) return false;
    final hide = _scrollHide.update(
      notification,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
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
    final away = rail ? Offset(0, sign) : Offset(sign, 0);
    final tween = i == _current
        ? Tween<Offset>(begin: away, end: Offset.zero)
        : Tween<Offset>(begin: Offset.zero, end: -away);
    return _switch.drive(
      tween.chain(CurveTween(curve: MotionTokens.branchSwitchCurve)),
    );
  }

  Widget _buildRail(
    BuildContext context,
    List<HomeDestination> shown, {
    required bool extended,
  }) {
    return NavigationRail(
      selectedIndex: homeBarIndexOf(shown, _current),
      onDestinationSelected: (index) => _select(shown[index].branchIndex),
      extended: extended,
      minWidth: HomeShellChrome.railWidth,
      minExtendedWidth: HomeShellChrome.extendedRailWidth,
      // A landscape phone, a large text scale or a short desktop window
      // can be too short for every destination.
      scrollable: true,
      labelType: extended ? null : NavigationRailLabelType.all,
      destinations: [
        for (final d in homeDestinations(context, shown))
          NavigationRailDestination(
            icon: Icon(d.icon, size: 26),
            label: Text(d.label),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final arrangement = ref.watch(homeArrangementProvider);
    final order = [...arrangement.shown, ...arrangement.hidden];
    _barBranches = [for (final d in arrangement.shown) d.branchIndex];
    final enclosingRouteIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final width = MediaQuery.sizeOf(context).width;
    final rail = AppBreakpoints.useNavigationRail(width);
    // An immersive page (the novel reader) takes the rail's room too, as it
    // covers the bottom bar on a phone.
    final railShown = rail && !ref.watch(shellRailHiddenProvider);
    final extended = AppBreakpoints.useExtendedRail(width);
    final bottomBarExtent = rail
        ? 0.0
        : FuncBottomNav.restingExtent(MediaQuery.paddingOf(context).bottom);
    final branches = Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          Offstage(
            offstage: i != _current && i != _outgoing,
            // Only the leaving branch freezes: its texture slides in a
            // single draw while the incoming branch runs live — entrances,
            // image fades and press feedback keep animating through the
            // switch instead of jumping at the end.
            child: TickerMode(
              enabled: i == _current,
              child: IgnorePointer(
                ignoring: i != _current,
                // A branch mounting off screen pushes its first route, which
                // would take the focus from the text field on screen.
                child: ExcludeFocus(
                  excluding: i != _current,
                  child: ExcludeSemantics(
                    excluding: i != _current,
                    child: BranchActivityScope(
                      active: enclosingRouteIsCurrent && i == _current,
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
                              ? widget.children[i]
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
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
    return HomeShellChrome(
      bottomBarExtent: bottomBarExtent,
      railExtent: railShown
          ? (extended
                    ? HomeShellChrome.extendedRailWidth
                    : HomeShellChrome.railWidth) +
                _railDividerWidth
          : 0,
      bottomBarVisibleExtent: _navBarVisibleExtent,
      bottomBarVisibility: _navVisibility,
      onBranchRootScroll: _onBranchRootScroll,
      child: _HomeBranchScope(
        channel: _reTap,
        child: rail
            ? Row(
                children: [
                  if (railShown) ...[
                    _buildRail(context, arrangement.shown, extended: extended),
                    const VerticalDivider(
                      thickness: _railDividerWidth,
                      width: _railDividerWidth,
                    ),
                  ],
                  Expanded(child: strip),
                ],
              )
            : strip,
      ),
    );
  }
}

/// Marks whether a branch Navigator's subtree is the one on screen. A
/// PageRoute's predictive-back check uses this non-dependent lookup so only
/// the visible branch can claim the gesture.
class BranchActivityScope extends InheritedWidget {
  const BranchActivityScope({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  static BranchActivityScope? maybeOf(BuildContext context) =>
      context
              .getElementForInheritedWidgetOfExactType<BranchActivityScope>()
              ?.widget
          as BranchActivityScope?;

  @override
  bool updateShouldNotify(BranchActivityScope oldWidget) =>
      active != oldWidget.active;
}

const _still = AlwaysStoppedAnimation<Offset>(Offset.zero);

const double _railDividerWidth = 1;

class _HomeBranchScope extends InheritedWidget {
  const _HomeBranchScope({required this.channel, required super.child});

  final ReTapChannel channel;

  @override
  bool updateShouldNotify(_HomeBranchScope oldWidget) =>
      channel != oldWidget.channel;
}
