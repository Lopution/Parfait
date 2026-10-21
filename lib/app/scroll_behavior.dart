import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'motion/motion_tokens.dart';

/// App-wide scroll behavior: on desktop the mouse and trackpad drag like
/// touch (Flutter's default excludes them, leaving wheel-only scrolling).
/// Wheel smoothing itself is per-scrollable — see `SmoothWheelScroll`.
///
/// Touch physics follow Android's lists app-wide ([FuncScrollPhysics]):
/// the fling of `OverScroller` and a hard stop at both ends, with Android
/// 12's stretch at the ends ([stretchOverscroll]). Feeds run EasyRefresh's
/// physics on the same fling (see `PullToRefresh`), so
/// detail/settings/search pages, profile NestedScrollView outer scrolls and
/// feed scrolls share one scheme.
///
/// Vertical lists show a scrollbar while a mouse is connected
/// ([mouseScrollbar]).
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
      const FuncScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => stretchOverscroll(context, child, details);

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

/// [child] with the edge effect of Android 12's lists: a drag past an end
/// stretches the content and a fling into one stretches by its speed,
/// both springing back, while the physics still stop the list at the end.
/// Other platforms, reduced motion and the scrollable inside a text
/// control keep the bare edge, and so does a NestedScrollView's outer
/// scroll: its body's lists stretch, as only the RecyclerView under an
/// `AppBarLayout` does, and the outer one stretching too at the end of a
/// fling doubled the effect.
///
/// [refreshAtLeadingEdge]: the vertical list pulls a refresh header out at
/// its top. A drag there is the header's alone, so it does not stretch; a
/// fling into the top still does, as under `SwipeRefreshLayout`.
Widget stretchOverscroll(
  BuildContext context,
  Widget child,
  ScrollableDetails details, {
  bool refreshAtLeadingEdge = false,
}) {
  if (defaultTargetPlatform != TargetPlatform.android ||
      textScrollPhysics(context) != null ||
      details.controller?.debugLabel == _nestedOuterLabel ||
      !MotionTokens.enabled(context)) {
    return child;
  }
  final pullsRefresh =
      refreshAtLeadingEdge &&
      axisDirectionToAxis(details.direction) == Axis.vertical;
  return StretchingOverscrollIndicator(
    axisDirection: details.direction,
    clipBehavior: details.decorationClipBehavior ?? Clip.hardEdge,
    notificationPredicate: pullsRefresh
        ? _notRefreshPull
        : defaultScrollNotificationPredicate,
    child: child,
  );
}

/// The debug label NestedScrollView gives its outer controller ('inner'
/// for the body's).
const _nestedOuterLabel = 'outer';

/// Every notification but a drag past the leading edge: the indicator
/// reads a negative overscroll as the leading edge's.
bool _notRefreshPull(ScrollNotification notification) =>
    defaultScrollNotificationPredicate(notification) &&
    !(notification is OverscrollNotification &&
        notification.dragDetails != null &&
        notification.overscroll < 0);

/// The physics of the scrollable a text control (`SelectableText`,
/// `TextField`) keeps inside its [EditableText], or null for any other
/// scrollable. That scrollable takes its physics from the nearest scroll
/// behavior; always scrollable, text that fits followed the finger and the
/// page under it stayed put. Without that parent, text that fits takes no
/// drag and text that overflows still scrolls, on the app's physics.
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
      controller.debugLabel == _nestedOuterLabel) {
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

/// The app's list physics: [ClampingScrollPhysics], as Android lists with
/// `overScrollMode="never"` scroll. A fling runs `OverScroller`'s curve
/// ([ClampingScrollSimulation]) and both a fling and a drag stop at the
/// ends.
class FuncScrollPhysics extends ClampingScrollPhysics {
  const FuncScrollPhysics({super.parent});

  @override
  FuncScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      FuncScrollPhysics(parent: buildParent(ancestor));
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
/// app's list physics below stop the first and last page at the edge.
/// Like a fling, the snap carries on the finger's motion, so the
/// reduced-motion gate and the animation speed leave it alone, as they
/// leave ViewPager's scroller.
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
