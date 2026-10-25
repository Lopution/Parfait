import 'package:material_ui/material_ui.dart';

import '../motion/still_work.dart';
import '../motion/swipe_paging.dart';

/// Sideways drag for a page's own tabs ([SwipePaging]). At the first or
/// last tab a swipe outwards goes to the enclosing [SwipePagerScope] (the
/// home branches) when it has a page that way, and otherwise pulls the
/// body on a rubber band.
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

  @override
  State<TabSwipeSwitcher> createState() => _TabSwipeSwitcherState();
}

class _TabSwipeSwitcherState extends State<TabSwipeSwitcher>
    with SingleTickerProviderStateMixin, StillWork, SwipePaging {
  /// How far the tabs are pulled past the first or last one, in tabs. The
  /// controller stays between those, so the body slides by this instead.
  final _overscroll = ValueNotifier<double>(0);

  TabController get _tc => widget.tabController;

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
    // A new controller (the tab list changed): a swipe in flight indexes
    // the old list.
    stopPaging();
    _overscroll.value = 0;
    scheduleStillWork();
  }

  @override
  void dispose() {
    _tc.removeListener(_onTabChanged);
    _overscroll.dispose();
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

  @override
  int get pageCount => _tc.length;

  @override
  double get pagePosition =>
      (_tc.animation?.value ?? _tc.index.toDouble()) + _overscroll.value;

  // A tap on the tab bar mid-settle animates the controller itself.
  @override
  void showPagePosition(double position) {
    if (_tc.indexIsChanging) return;
    final inRange = position.clamp(0.0, _tc.length - 1.0);
    _overscroll.value = position - inRange;
    // As TabBarView: only a drag a whole tab away moves the index early.
    if ((inRange - _tc.index).abs() > 1) _tc.index = inRange.round();
    _tc.offset = (inRange - _tc.index).clamp(-1.0, 1.0);
  }

  @override
  void landOnPage(int page) {
    _overscroll.value = 0;
    if (_tc.indexIsChanging) return;
    _tc.index = page;
    _tc.offset = 0;
  }

  @override
  void pageDragStart(DragStartDetails details) {
    super.pageDragStart(details);
    if (_tc.indexIsChanging) {
      _tc.index = _tc.animation!.value.round().clamp(0, _tc.length - 1);
    }
    final prepare = widget.prepareTab;
    // Mid-settle the index still names the tab the last swipe left.
    final origin = pagePosition.round();
    for (final i in [origin + 1, origin - 1]) {
      if (prepare != null && i >= 0 && i < _tc.length) prepare(i);
    }
  }

  /// At rest on its first or last tab, a swipe outwards goes to the
  /// enclosing pager when that has a page there.
  bool _yieldsTo(double dx) {
    final forward =
        (dx < 0) == (Directionality.of(context) == TextDirection.ltr);
    final edge = forward ? _tc.length - 1.0 : 0.0;
    if (pageSettling || (pagePosition - edge).abs() > 1e-3) return false;
    return SwipePagerScope.maybeOf(context)?.canPage(forward) ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final ltr = Directionality.of(context) == TextDirection.ltr;
    return swipeGestures(
      yieldsTo: _yieldsTo,
      child: NotificationListener<ScrollNotification>(
        onNotification: trackStillScroll,
        child: ValueListenableBuilder<double>(
          valueListenable: _overscroll,
          builder: (context, overscroll, child) => FractionalTranslation(
            translation: Offset(ltr ? -overscroll : overscroll, 0),
            child: child,
          ),
          child: widget.child,
        ),
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
