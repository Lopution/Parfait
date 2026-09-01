import 'package:flutter/material.dart';

/// The one shared pull-to-refresh wrapper used by every feed.
///
/// An earlier version ran its own scroll-notification state machine next to
/// Flutter's — a second drag-distance accumulator, a second threshold, and a
/// hand-drawn indicator — and every U1 defect came out of the two disagreeing:
/// overscroll produced after the pointer lifted reopened tracking, a pull that
/// never armed never got a cancel callback so the indicator stayed on screen,
/// and `_handleRefresh` vetoed refreshes the framework had already decided to
/// run.
///
/// This version keeps the framework as the single authority and takes only two
/// things from it:
///
/// * **when to refresh** — `RefreshIndicator.noSpinner` still owns the
///   threshold, the pointer state, the ballistic handling and the callback;
/// * **what to draw** — the indicator's position is a pure function of the
///   scrollable's own overscroll, and its discrete phase comes from
///   `onStatusChange`.
///
/// Nothing here accumulates a distance, decides a threshold, or overrides the
/// framework's decision, which is what makes it different from the version it
/// replaces.
class PullToRefresh extends StatefulWidget {
  const PullToRefresh({super.key, required this.onRefresh, required this.child});

  final RefreshCallback onRefresh;
  final Widget child;

  @override
  State<PullToRefresh> createState() => _PullToRefreshState();
}

class _PullToRefreshState extends State<PullToRefresh> {
  /// Height the indicator occupies; used to park it just off-screen at rest.
  static const _indicatorExtent = 40.0;

  /// How far down the indicator is allowed to travel while dragging, and where
  /// it sits while the refresh callback runs.
  static const _maxDisplacement = 48.0;
  static const _refreshingTop = 24.0;

  /// Mirror of the scrollable's leading-edge overscroll — re-read from
  /// `metrics.pixels` on every notification rather than accumulated, so it
  /// cannot drift out of step with the scroll position the way a
  /// hand-maintained drag distance did.
  ///
  /// Driving the indicator from this is what makes "reversing the pull must
  /// not scroll the list" work: the overscroll reaches 0 at exactly the moment
  /// the list starts moving, so the indicator is gone by then. The framework's
  /// own spinner cannot do this — once armed it pins itself at two thirds of
  /// its travel (`_kDragSizeFactorLimit`) and stays on screen while the list
  /// scrolls away underneath.
  final _overscroll = ValueNotifier<double>(0);
  final _status = ValueNotifier<RefreshIndicatorStatus?>(null);

  @override
  void dispose() {
    _overscroll.dispose();
    _status.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final metrics = notification.metrics;
    final past = metrics.minScrollExtent - metrics.pixels;
    _overscroll.value = past > 0 ? past : 0;
    return false;
  }

  static bool _isRefreshing(RefreshIndicatorStatus? status) =>
      status == RefreshIndicatorStatus.snap ||
      status == RefreshIndicatorStatus.refresh;

  /// Whether the framework currently considers a pull to be in progress.
  ///
  /// Overscroll alone is not enough to draw the indicator: a flick that
  /// settles against the top edge produces overscroll with no finger on
  /// screen, and drawing on that is exactly the "the icon appears after I let
  /// go" defect. The framework already answers this question — it only enters
  /// `drag` from a scroll that started at the edge under a real pointer — so
  /// take the answer instead of re-deriving it.
  static bool _isDragging(RefreshIndicatorStatus? status) =>
      status == RefreshIndicatorStatus.drag ||
      status == RefreshIndicatorStatus.armed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ScrollConfiguration(
      // Bouncing physics is what makes the requirement expressible at all.
      // Under clamping physics a pull leaves `pixels` at 0, so the distance
      // the indicator occupies does not exist in the scroll coordinate space
      // and a reverse gesture goes straight into `applyUserOffset` — the list
      // scrolls while the indicator is still on screen. Bouncing stores that
      // distance as negative `pixels`, so a reverse gesture has to pay it back
      // before it can drive the list.
      //
      // The edge glow is off because the bounce already says "this is the
      // end"; showing both says it twice.
      behavior: ScrollConfiguration.of(
        context,
      ).copyWith(physics: const BouncingScrollPhysics(), overscroll: false),
      child: RefreshIndicator.noSpinner(
        onRefresh: widget.onRefresh,
        onStatusChange: (status) => _status.value = status,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Stack(
            children: [
              widget.child,
              // Listening rather than calling setState keeps the feed itself
              // out of the rebuild: only the indicator repaints per frame.
              ValueListenableBuilder<double>(
                valueListenable: _overscroll,
                builder: (context, overscroll, _) =>
                    ValueListenableBuilder<RefreshIndicatorStatus?>(
                      valueListenable: _status,
                      builder: (context, status, _) {
                        final refreshing = _isRefreshing(status);
                        if (!refreshing &&
                            !(_isDragging(status) && overscroll > 0)) {
                          return const SizedBox.shrink();
                        }
                        final top = refreshing
                            ? _refreshingTop
                            : (overscroll - _indicatorExtent).clamp(
                                -_indicatorExtent,
                                _maxDisplacement,
                              );
                        return Positioned(
                          top: top,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: RefreshProgressIndicator(
                              color: colors.primary,
                              backgroundColor: colors.surface,
                              strokeWidth: 3,
                            ),
                          ),
                        );
                      },
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
