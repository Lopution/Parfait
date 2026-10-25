import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform/app_root_pipeline_owner.dart';

/// App-wide scroll behavior: on desktop the mouse and trackpad drag like
/// touch (Flutter's default excludes them, leaving wheel-only scrolling).
/// Wheel smoothing itself is per-scrollable — see `SmoothWheelScroll`.
///
/// Touch physics follow the EasyRefresh convention app-wide: feed pages get
/// their feel from `_ERScrollPhysics` (a `BouncingScrollPhysics` with an
/// always-scrollable parent and no platform overscroll glow, a fling
/// stopping at the ends), and before this every other page ran platform
/// `ClampingScrollPhysics` instead — one app, two physics stacks. Mirroring
/// the same feel here ([FuncScrollPhysics]) keeps detail/settings/search
/// pages, profile NestedScrollView outer scrolls and feed scrolls on a
/// single scheme.
///
/// Vertical lists show a scrollbar while a mouse is connected
/// ([mouseScrollbar]), and no scrollable pushes semantics while it scrolls
/// ([ScrollSemanticsHold]).
class FuncScrollBehavior extends MaterialScrollBehavior {
  const FuncScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      textScrollPhysics(context) ??
      const NoDragDeadZonePhysics(
        parent: FuncScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      );

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => ScrollSemanticsHold(child: child);

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => switch (getPlatform(context)) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => super.buildScrollbar(context, child, details),
    _ => mouseScrollbar(child, details),
  };
}

/// Holds the app's semantics pushes ([AppRootPipelineOwner.holdSemantics])
/// while the scrollable it wraps scrolls: a drag, a fling or an animated
/// scroll. Each push during a fling cost 7.5–11 ms of a frame with an
/// accessibility service on; the platform gets the final tree once the
/// scroll and the animations after it stop.
///
/// Every scroll behavior the app installs wraps its overscroll indicator in
/// it. A text control's scrollable turns the indicator off and is not held.
///
/// The hold follows the scroll position, not its notifications: a
/// scrollable unmounted or given a new position mid-scroll disposes the old
/// position without an end notification, and a missed release would keep
/// every later hold expired.
class ScrollSemanticsHold extends StatefulWidget {
  const ScrollSemanticsHold({super.key, required this.child});

  final Widget child;

  @override
  State<ScrollSemanticsHold> createState() => _ScrollSemanticsHoldState();
}

class _ScrollSemanticsHoldState extends State<ScrollSemanticsHold> {
  ScrollableState? _scrollable;
  ScrollPosition? _position;
  VoidCallback? _release;

  bool _onNotification(ScrollNotification notification) {
    if (notification is! ScrollStartNotification ||
        notification.depth != 0 ||
        _release != null) {
      return false;
    }
    // The notification comes from inside the scrollable; this widget sits
    // above its scope.
    final scrollable = notification.context
        ?.findAncestorStateOfType<ScrollableState>();
    final position = scrollable?.position;
    // A jump starts and ends in one call without ever scrolling.
    if (position == null || !position.isScrollingNotifier.value) return false;
    _scrollable = scrollable;
    _position = position..isScrollingNotifier.addListener(_onScrolling);
    _release = AppRootPipelineOwner.holdSemantics();
    return false;
  }

  void _onScrolling() {
    if (!_position!.isScrollingNotifier.value) _stop();
  }

  void _stop() {
    _position?.isScrollingNotifier.removeListener(_onScrolling);
    _position = null;
    _scrollable = null;
    _release?.call();
    _release = null;
  }

  @override
  void didUpdateWidget(ScrollSemanticsHold oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The scrollable rebuilds this right after replacing its position (new
    // physics); the new one takes over a running scroll without a start.
    final scrollable = _scrollable;
    if (scrollable == null || identical(scrollable.position, _position)) {
      return;
    }
    final next = scrollable.position;
    if (!next.isScrollingNotifier.value) return _stop();
    _position!.isScrollingNotifier.removeListener(_onScrolling);
    _position = next..isScrollingNotifier.addListener(_onScrolling);
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onNotification,
        child: widget.child,
      );
}

/// The physics of the scrollable a text control (`SelectableText`,
/// `TextField`) keeps inside its [EditableText], or null for any other
/// scrollable. That scrollable takes its physics from the nearest scroll
/// behavior; always scrollable, text that fits followed the finger and the
/// page under it stayed put. Without that parent, text that fits takes no
/// drag and text that overflows still scrolls, with the app's bounce.
///
/// Every scroll behavior the app installs asks this first.
ScrollPhysics? textScrollPhysics(BuildContext context) =>
    context.findAncestorStateOfType<EditableTextState>() == null
    ? null
    : const FuncScrollPhysics(parent: RangeMaintainingScrollPhysics());

/// [child], a vertical scroll view, with a [Scrollbar] while a mouse is
/// connected: a wheel gives no sense of a list's length or place, and the
/// thumb drags. Touch-only devices keep the platform's bare lists.
///
/// NestedScrollView's coordinated controllers drive several positions and
/// cannot back one thumb; their views stay bare, as on desktop.
Widget mouseScrollbar(Widget child, ScrollableDetails details) {
  final controller = details.controller;
  if (axisDirectionToAxis(details.direction) != Axis.vertical ||
      controller == null ||
      controller.positions.length > 1 ||
      controller.debugLabel == 'inner' ||
      controller.debugLabel == 'outer') {
    return child;
  }
  return _MouseScrollbar(controller: controller, child: child);
}

class _MouseScrollbar extends StatefulWidget {
  const _MouseScrollbar({required this.controller, required this.child});

  final ScrollController controller;
  final Widget child;

  @override
  State<_MouseScrollbar> createState() => _MouseScrollbarState();
}

class _MouseScrollbarState extends State<_MouseScrollbar> {
  final MouseTracker _mouse = RendererBinding.instance.mouseTracker;

  /// Keeps the viewport's subtree, and every state in it, when a mouse
  /// coming or going adds or drops the scrollbar above it.
  final GlobalKey _viewportKey = GlobalKey();
  late bool _connected = _mouse.mouseIsConnected;

  @override
  void initState() {
    super.initState();
    _mouse.addListener(_onMouseChange);
  }

  @override
  void dispose() {
    _mouse.removeListener(_onMouseChange);
    super.dispose();
  }

  void _onMouseChange() {
    final connected = _mouse.mouseIsConnected;
    if (connected != _connected) setState(() => _connected = connected);
  }

  @override
  Widget build(BuildContext context) {
    final viewport = KeyedSubtree(key: _viewportKey, child: widget.child);
    if (!_connected) return viewport;
    return Scrollbar(controller: widget.controller, child: viewport);
  }
}

/// [BouncingScrollPhysics] whose fling stops at either end, the way the
/// feed's EasyRefresh footer does with `hitOver` off: a fling into the end
/// of a page that is loading more no longer overshoots and springs back
/// against the content arriving. A drag still pulls past the ends and
/// springs back on release.
class FuncScrollPhysics extends BouncingScrollPhysics {
  const FuncScrollPhysics({super.parent});

  @override
  FuncScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      FuncScrollPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final simulation = super.createBallisticSimulation(position, velocity);
    // Out of range a drag left the page pulled past an end: spring back.
    if (simulation == null || position.outOfRange) return simulation;
    return _EdgeStopSimulation(
      simulation,
      min: position.minScrollExtent,
      max: position.maxScrollExtent,
    );
  }
}

/// [parent] without the drag dead zone of [BouncingScrollPhysics]: iOS
/// holds a drag for 3.5 more pixels past the touch slop, at its start and
/// again after every pause, which reads as sticky on a slow drag. Android
/// follows the finger once the slop is crossed. Bouncing physics declares
/// the threshold non-nullable, so it is dropped by this wrapper on top;
/// everything else is the parent's.
class NoDragDeadZonePhysics extends ScrollPhysics {
  const NoDragDeadZonePhysics({required ScrollPhysics super.parent});

  @override
  NoDragDeadZonePhysics applyTo(ScrollPhysics? ancestor) =>
      NoDragDeadZonePhysics(parent: buildParent(ancestor)!);

  @override
  double? get dragStartDistanceMotionThreshold => null;
}

/// A pager's snap to its page on Material's default spatial spring
/// (damping ratio 0.9, stiffness 700): about 300 ms from release to the
/// end of the scroll. The framework's scroll spring (mass 0.5, stiffness
/// 100, overdamped) looks settled after about 0.45 s and ends the scroll
/// after about 0.7 s, and a pager builds its next pages only when the
/// scroll ends. ViewPager lands within 600 ms on a quintic ease-out.
///
/// Give it as a [PageView]'s physics: the page physics on top still picks
/// the target page and starts the snap at the release velocity, and the
/// app's list physics below keep their own spring for the bounce past the
/// first and last page. Like a fling, the snap carries on the finger's
/// motion, so the reduced-motion gate and the animation speed leave it
/// alone, as they leave ViewPager's scroller.
class PageSnapPhysics extends ScrollPhysics {
  const PageSnapPhysics({super.parent});

  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 700,
    ratio: 0.9,
  );

  @override
  PageSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      PageSnapPhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => _spring;
}

/// Runs [_inner] until it would leave [min]..[max], then rests at the edge.
class _EdgeStopSimulation extends Simulation {
  _EdgeStopSimulation(this._inner, {required this.min, required this.max})
    : super(tolerance: _inner.tolerance);

  final Simulation _inner;
  final double min;
  final double max;

  bool _past(double time) {
    final x = _inner.x(time);
    return x < min || x > max;
  }

  @override
  double x(double time) => clampDouble(_inner.x(time), min, max);

  @override
  double dx(double time) => _past(time) ? 0 : _inner.dx(time);

  @override
  bool isDone(double time) => _past(time) || _inner.isDone(time);
}

/// How much further than the device's touch slop a sideways pager's own
/// drag has to travel before it starts: Android's ViewPager uses the paging
/// slop, twice the touch slop. Against a vertical list starting at the
/// touch slop, a straight swipe steeper than about 27° (tan 0.5) scrolls
/// the list instead of paging. A single move that crosses both slops goes
/// to whichever recognizer handles it first, so this approximates the
/// ViewPager split rather than reproducing it.
const pagingSlopFactor = 2.0;

/// The gesture settings of a sideways pager's own drag: [device]'s touch
/// slop times [pagingSlopFactor]. A recognizer given these also takes its
/// default fling distance from them; keep the device slop there, or a
/// short quick flick stops counting.
DeviceGestureSettings pagingGestureSettings(DeviceGestureSettings? device) =>
    DeviceGestureSettings(
      touchSlop: (device?.touchSlop ?? kTouchSlop) * pagingSlopFactor,
    );

/// Gives [child], a [PageView], the paging slop ([pagingSlopFactor]) for
/// its own drag. Its Scrollable reads the slop from [MediaQuery]; each page
/// wraps itself in [PagingSlopPage] to get the device's slop back, so taps,
/// zooms and drags on the page keep theirs. The pager's fling distance
/// comes from its physics and stays unchanged.
class PagingSlop extends StatelessWidget {
  const PagingSlop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final data = MediaQuery.of(context);
    final device = data.gestureSettings;
    return _DeviceGestureSettings(
      settings: device,
      child: MediaQuery(
        data: data.copyWith(gestureSettings: pagingGestureSettings(device)),
        child: child,
      ),
    );
  }
}

/// A page of a [PagingSlop] pager, back on the device's gesture settings
/// while [restore] holds.
///
/// A pan or scale recognizer on the page accepts at twice the touch slop,
/// which ties with the pager's paging slop, and the inner recognizer wins a
/// tie. Such a page (the viewer's zoomable image) passes false while the
/// pager can page, keeping its own slop above the pager's.
class PagingSlopPage extends StatelessWidget {
  const PagingSlopPage({super.key, this.restore = true, required this.child});

  final bool restore;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final device = context
        .dependOnInheritedWidgetOfExactType<_DeviceGestureSettings>()
        ?.settings;
    if (device == null) return child;
    final data = MediaQuery.of(context);
    // Always a MediaQuery, so flipping [restore] keeps the page's state.
    return MediaQuery(
      data: restore ? data.copyWith(gestureSettings: device) : data,
      child: child,
    );
  }
}

class _DeviceGestureSettings extends InheritedWidget {
  const _DeviceGestureSettings({required this.settings, required super.child});

  final DeviceGestureSettings settings;

  @override
  bool updateShouldNotify(_DeviceGestureSettings oldWidget) =>
      settings != oldWidget.settings;
}
