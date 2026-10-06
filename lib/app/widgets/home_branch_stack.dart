import 'package:animations/animations.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/debug/frame_probe.dart';
import '../layout/app_breakpoints.dart';
import '../motion/motion_tokens.dart';
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
void reTapScrollToTop(BuildContext context, ScrollController controller) {
  if (!controller.hasClients) return;
  final duration = MotionTokens.resolve(context, MotionTokens.fast);
  if (duration == Duration.zero) {
    controller.jumpTo(0);
  } else {
    controller.animateTo(0, duration: duration, curve: MotionTokens.fastCurve);
  }
}

/// The home shell container. Branches remain mounted in place so each branch
/// retains its navigator stack and scroll state; switching only fades between
/// the current and outgoing branch.
class HomeBranchStack extends StatefulWidget {
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
  State<HomeBranchStack> createState() => _HomeBranchStackState();
}

class _HomeBranchStackState extends State<HomeBranchStack>
    with TickerProviderStateMixin {
  late final AnimationController _switch = AnimationController(
    vsync: this,
    value: 1,
  );
  late final AnimationController _navVisibility;

  /// Freezes the outgoing branch into one texture while it fades through.
  /// Fading a live page re-renders it into a full-screen offscreen layer
  /// on every frame; a texture takes the opacity in a single draw. The
  /// incoming branch stays live — its ticker, entrances and image fades
  /// keep running so the switch never lands on a frozen page.
  final SnapshotController _switchSnapshot = SnapshotController();

  /// Never armed: assigned to every branch that is not fading out, so the
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
  double _scrollAccum = 0;
  double? _lastPixels;
  BuildContext? _lastScrollable;

  /// `accessibleNavigation` below TouchExplorationScope: TalkBack is
  /// exploring, not merely some assistive service reading nodes.
  bool _touchExploration = false;

  @override
  void initState() {
    super.initState();
    _current = widget.shell.currentIndex;
    _navVisibility = AnimationController(vsync: this, value: 1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _switch.duration = MotionTokens.resolve(context, MotionTokens.branchSwitch);
    _navVisibility
      ..duration = MotionTokens.resolve(context, MotionTokens.navBarShow)
      ..reverseDuration = MotionTokens.resolve(
        context,
        MotionTokens.navBarHide,
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
    _switch
      ..duration = duration
      ..forward(from: 0).whenCompleteOrCancel(() {
        FrameProbe.instance.exit('branch switch');
        if (!mounted || generation != _switchGeneration) return;
        _switchSnapshot.allowSnapshotting = false;
        setState(() => _outgoing = null);
      });
  }

  @override
  void dispose() {
    _reTap.dispose();
    _switch.dispose();
    _switchSnapshot.dispose();
    _idleSnapshot.dispose();
    _navVisibility.dispose();
    _navBarVisibleExtent.dispose();
    super.dispose();
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

  bool _onScrollNotification(ScrollNotification notification) {
    if (_touchExploration) return false;
    if (notification.depth != 0) return false;
    if (notification.metrics.axis != Axis.vertical) return false;
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
    _scrollAccum = (_scrollAccum * delta < 0) ? delta : _scrollAccum + delta;
    final slop = MediaQuery.maybeGestureSettingsOf(context)?.touchSlop ?? 8.0;
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
    if (_navVisibility.status.isForwardOrCompleted != hidden) return;
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

  Widget _buildRail(BuildContext context) {
    final extended = AppBreakpoints.useExtendedRail(
      MediaQuery.sizeOf(context).width,
    );
    final destinations = homeDestinations(context);
    return NavigationRail(
      selectedIndex: _current,
      onDestinationSelected: _select,
      extended: extended,
      labelType: extended ? null : NavigationRailLabelType.all,
      destinations: [
        for (final d in destinations)
          NavigationRailDestination(
            icon: Icon(d.icon, size: 26),
            label: Text(d.label),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final enclosingRouteIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final rail = AppBreakpoints.useNavigationRail(
      MediaQuery.sizeOf(context).width,
    );
    final bottomBarExtent = rail
        ? 0.0
        : FuncBottomNav.restingExtent(MediaQuery.paddingOf(context).bottom);
    final strip = NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          for (var i = 0; i < widget.children.length; i++)
            Offstage(
              offstage: i != _current && i != _outgoing,
              // Only the leaving branch freezes: its texture takes the
              // fade in a single draw while the incoming branch runs live —
              // entrances, image fades and press feedback keep animating
              // through the switch instead of jumping at the end.
              child: TickerMode(
                enabled: i == _current,
                child: IgnorePointer(
                  ignoring: i != _current,
                  child: ExcludeSemantics(
                    excluding: i != _current,
                    child: BranchActivityScope(
                      active: enclosingRouteIsCurrent && i == _current,
                      child: FadeThroughTransition(
                        animation: i == _current
                            ? _switch
                            : kAlwaysCompleteAnimation,
                        secondaryAnimation: i == _outgoing
                            ? _switch
                            : kAlwaysDismissedAnimation,
                        fillColor: Colors.transparent,
                        // Always in the tree, so starting a switch never
                        // remounts a branch; only the outgoing branch paints
                        // from a texture.
                        child: SnapshotWidget(
                          // A branch showing a platform view paints live.
                          mode: SnapshotMode.permissive,
                          controller: i == _outgoing
                              ? _switchSnapshot
                              : _idleSnapshot,
                          child: widget.children[i],
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
                selectedIndex: _current,
                onSelected: _select,
                scrollVisibility: _navVisibility,
                visibleExtent: _navBarVisibleExtent,
              ),
            ),
        ],
      ),
    );
    return HomeShellChrome(
      bottomBarExtent: bottomBarExtent,
      bottomBarVisibleExtent: _navBarVisibleExtent,
      child: _HomeBranchScope(
        channel: _reTap,
        child: rail
            ? Row(
                children: [
                  _buildRail(context),
                  const VerticalDivider(thickness: 1, width: 1),
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

class _HomeBranchScope extends InheritedWidget {
  const _HomeBranchScope({required this.channel, required super.child});

  final ReTapChannel channel;

  @override
  bool updateShouldNotify(_HomeBranchScope oldWidget) =>
      channel != oldWidget.channel;
}
