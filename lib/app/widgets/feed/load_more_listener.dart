import 'package:flutter/widgets.dart';

/// Asks for a feed's next page while the end of the list below is less
/// than [screens] viewports away: as the user scrolls, and once after the
/// list mounts and after each commit. A page that leaves the list short of
/// the screen, or still inside the zone, asks for the next one without a
/// scroll, as RecyclerView checks again after a submit.
///
/// A size change alone asks for nothing: the tail swapping its spinner for
/// an error must not retry the failed page. The feed's controller drops
/// repeated asks and paces them (`FeedPagingPolicy`). Only the list
/// directly below counts: a nested row reaching its end asks for nothing.
class LoadMoreListener extends StatefulWidget {
  const LoadMoreListener({
    super.key,
    required this.itemCount,
    required this.onLoadMore,
    required this.child,
  });

  /// Viewports of content left below the screen at which the next page is
  /// asked for. A page is 30 works, about three screens of cards.
  static const screens = 3.0;

  /// Items the list holds; a change is a commit, checked again after the
  /// frame that lays it out.
  final int itemCount;
  final VoidCallback onLoadMore;
  final Widget child;

  @override
  State<LoadMoreListener> createState() => _LoadMoreListenerState();
}

class _LoadMoreListenerState extends State<LoadMoreListener> {
  BuildContext? _scrollable;

  /// A mount or commit not yet checked against the laid-out list.
  var _pending = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _recheck());
  }

  @override
  void didUpdateWidget(LoadMoreListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.itemCount != oldWidget.itemCount) {
      _pending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _recheck());
    }
  }

  // A commit that changes no size dispatches no notification: a list too
  // short to scroll, laid out whole. Rows appended past the laid-out ones
  // are not laid out at all (`SliverMultiBoxAdaptorElement.performRebuild`
  // only looks one row further at the end), so a list that scrolls keeps
  // its old estimated end; its check waits for the notification of the
  // layout that corrects it, at the latest the next scroll. Before the
  // list's first notification there is no position to read; that
  // notification runs the check instead.
  void _recheck() {
    final scrollable = _scrollable;
    if (!mounted || !_pending || scrollable == null || !scrollable.mounted) {
      return;
    }
    final position = Scrollable.maybeOf(scrollable)?.position;
    if (position == null ||
        !position.hasContentDimensions ||
        position.maxScrollExtent > position.minScrollExtent) {
      return;
    }
    _pending = false;
    _check(position);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification &&
        _note(notification.depth, notification.context)) {
      _check(notification.metrics);
    }
    return false;
  }

  bool _onMetrics(ScrollMetricsNotification notification) {
    if (_note(notification.depth, notification.context) && _pending) {
      _pending = false;
      _check(notification.metrics);
    }
    return false;
  }

  /// Keeps the list's context; false for a nested scrollable.
  bool _note(int depth, BuildContext? scrollable) {
    if (depth != 0 || scrollable == null) return false;
    _scrollable = scrollable;
    return true;
  }

  void _check(ScrollMetrics metrics) {
    if (metrics.extentAfter <
        metrics.viewportDimension * LoadMoreListener.screens) {
      widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: _onMetrics,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: widget.child,
        ),
      );
}
