import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';

import '../motion/motion_tokens.dart';
import '../motion/still_work.dart';
import '../scroll_behavior.dart';

/// Sideways drag for a page's own tabs. The gesture stops at the first and
/// last tab; it never changes the home branch.
///
/// [prepareTab] builds the tab at an index and says whether it had to: the
/// tabs next to the one on screen are built ahead of a swipe, one at a time
/// on a still screen ([StillWork]), next before previous, as ViewPager
/// keeps its neighbours. A swipe that starts before then builds them in
/// its first frame rather than slide in an empty tab.
class TabSwipeSwitcher extends StatefulWidget {
  const TabSwipeSwitcher({
    super.key,
    required this.tabController,
    this.prepareTab,
    required this.child,
  });

  final TabController tabController;
  final bool Function(int index)? prepareTab;
  final Widget child;

  static const minFlingVelocity = 400.0;
  static const distanceFraction = 0.25;

  @override
  State<TabSwipeSwitcher> createState() => _TabSwipeSwitcherState();
}

class _TabSwipeSwitcherState extends State<TabSwipeSwitcher>
    with SingleTickerProviderStateMixin, StillWork {
  double _rawDx = 0;
  double _dragOrigin = 0;
  bool _active = false;
  AnimationController? _settle;
  int _settleTarget = 0;

  TabController get _tc => widget.tabController;
  bool get _ltr => Directionality.of(context) == TextDirection.ltr;
  double get _position => _tc.animation?.value ?? _tc.index.toDouble();

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTabChanged);
    scheduleStillWork();
  }

  @override
  void didUpdateWidget(TabSwipeSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tabController == oldWidget.tabController) return;
    oldWidget.tabController.removeListener(_onTabChanged);
    _tc.addListener(_onTabChanged);
    // A new controller (the tab list changed): a settle in flight and the
    // drag origin index the old list.
    _settle?.stop();
    _dragOrigin = _tc.index.toDouble();
    scheduleStillWork();
  }

  @override
  void dispose() {
    _tc.removeListener(_onTabChanged);
    _settle?.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tc.indexIsChanging) scheduleStillWork();
  }

  @override
  bool get stillWorkWaitsForImages => widget.prepareTab != null;

  @override
  bool runStillWork() {
    final prepare = widget.prepareTab;
    if (prepare == null) return false;
    final index = _tc.index;
    for (final i in [index + 1, index - 1]) {
      if (i >= 0 && i < _tc.length && prepare(i)) return true;
    }
    return false;
  }

  void _onDragStart(DragStartDetails details) {
    _active = true;
    _rawDx = 0;
    _settle?.stop();
    if (_tc.indexIsChanging) {
      _tc.index = _tc.animation!.value.round().clamp(0, _tc.length - 1);
    }
    _dragOrigin = _position;
    final prepare = widget.prepareTab;
    final origin = _dragOrigin.round();
    for (final i in [origin + 1, origin - 1]) {
      if (prepare != null && i >= 0 && i < _tc.length) prepare(i);
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _rawDx += details.delta.dx;
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0 || _tc.length < 2) return;
    final delta = (_ltr ? -details.delta.dx : details.delta.dx) / width;
    _writeTab((_position + delta).clamp(0.0, _tc.length - 1.0));
  }

  void _writeTab(double target) {
    if ((target - _tc.index).abs() > 0.5) {
      _tc.index = target.round().clamp(0, _tc.length - 1);
    }
    _tc.offset = (target - _tc.index).clamp(-1.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_active) return;
    _active = false;
    final width = MediaQuery.sizeOf(context).width;
    final velocity = details.primaryVelocity ?? 0;
    final fling = velocity.abs() >= TabSwipeSwitcher.minFlingVelocity;
    final position = _position;
    final base = _dragOrigin.round().clamp(0, _tc.length - 1);
    final moved = position - base;
    final committed =
        fling ||
        _rawDx.abs() >= width * TabSwipeSwitcher.distanceFraction ||
        moved.abs() >= TabSwipeSwitcher.distanceFraction;
    final forward = ((fling ? velocity : _rawDx) < 0) == _ltr;
    // The next tab in the release's direction from where the tabs are, as
    // ViewPager picks: flinging back from past halfway returns to the
    // first tab rather than skipping over it.
    final target = committed
        ? (forward ? position.ceil() : position.floor()).clamp(
            0,
            _tc.length - 1,
          )
        : base;
    _settleTo(target, velocity: velocity);
  }

  void _onDragCancel() {
    if (!_active) return;
    _active = false;
    _settleTo(_tc.index);
  }

  /// Carries the tabs to [target] on the [MotionSpring.spatialDefault]
  /// spring, starting at the finger's release [velocity] (pixels per
  /// second): a fling lands without slowing first, and a spring-back turns
  /// round instead of stalling. The index changes once, on landing, as a
  /// tab bar's own switch notifies its listeners after the animation.
  void _settleTo(int target, {double velocity = 0}) {
    final from = _position;
    _settleTarget = target;
    final spring = MotionTokens.spring(context, MotionSpring.spatialDefault);
    final width = MediaQuery.sizeOf(context).width;
    if (spring == null || width <= 0 || (from - target).abs() < 1e-4) {
      _settle?.stop();
      _tc.index = target;
      _tc.offset = 0;
      return;
    }
    final controller = _settle ??= AnimationController.unbounded(vsync: this)
      ..addListener(_applySettle)
      ..addStatusListener(_finishSettle);
    final tabsPerSecond = (_ltr ? -velocity : velocity) / width;
    controller.animateWith(
      SpringSimulation(
        spring,
        from,
        target.toDouble(),
        tabsPerSecond,
        snapToEnd: true,
      ),
    );
  }

  // A tap on the tab bar mid-settle animates the controller itself.
  void _applySettle() {
    if (_tc.indexIsChanging) return;
    _tc.offset = (_settle!.value - _tc.index).clamp(-1.0, 1.0);
  }

  void _finishSettle(AnimationStatus status) {
    if (status != AnimationStatus.completed || _tc.indexIsChanging) return;
    _tc.index = _settleTarget;
    _tc.offset = 0;
  }

  /// A [GestureDetector] horizontal drag with the paging slop: a swipe
  /// that leans towards vertical scrolls the tab's list instead. The fling
  /// distance stays the device slop.
  @override
  Widget build(BuildContext context) {
    final multitouch = ScrollConfiguration.of(
      context,
    ).getMultitouchDragStrategy(context);
    final device = MediaQuery.maybeGestureSettingsOf(context);
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        HorizontalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              HorizontalDragGestureRecognizer
            >(
              () => HorizontalDragGestureRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..onStart = _onDragStart
                ..onUpdate = _onDragUpdate
                ..onEnd = _onDragEnd
                ..onCancel = _onDragCancel
                ..multitouchDragStrategy = multitouch
                ..gestureSettings = pagingGestureSettings(device)
                ..minFlingDistance = device?.touchSlop ?? kTouchSlop,
            ),
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: trackStillScroll,
        child: widget.child,
      ),
    );
  }
}

/// Tab bodies arranged side by side and driven by the tab controller's live
/// animation. Each visited body stays mounted, preserving its scroll state;
/// a keyed body keeps it when the tabs are reordered.
class TabSlideStack extends StatelessWidget {
  const TabSlideStack({
    super.key,
    required this.controller,
    required this.children,
  });

  final TabController controller;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final animation = controller.animation;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    Widget stack(double position) => Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        for (var i = 0; i < children.length; i++)
          Offstage(
            key: switch (children[i].key) {
              final key? => ValueKey(key),
              null => null,
            },
            offstage: (i - position).abs() > 1.0,
            child: FractionalTranslation(
              translation: Offset(rtl ? position - i : i - position, 0),
              child: children[i],
            ),
          ),
      ],
    );
    if (animation == null) return stack(controller.index.toDouble());
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => stack(animation.value),
    );
  }
}

/// Re-reports [controller]'s list position after a tab switch, so the app
/// bar's scrolled-under state follows the tab on screen instead of the
/// last list that scrolled. [context] must sit inside the Scaffold's
/// notification scope but outside the feed lists: dispatching from there
/// reaches the ScrollNotificationObserver without passing the feeds' own
/// NotificationListeners — a synthetic zero-delta update must not trip
/// load-more or pull-to-refresh handlers. Runs after the frame: a tab
/// built by the switch has no position until then. A list that has not
/// been laid out yet (its route still covered) has nothing to report.
void announceTabScroll(BuildContext context, ScrollController controller) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted ||
        !controller.hasClients ||
        !controller.position.hasContentDimensions) {
      return;
    }
    ScrollUpdateNotification(
      metrics: controller.position,
      context: context,
      scrollDelta: 0,
    ).dispatch(context);
  });
}
