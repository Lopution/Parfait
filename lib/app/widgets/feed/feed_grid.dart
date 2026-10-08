import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../../core/platform/content_font_prefetch.dart';
import '../../motion/feed_entrance.dart';
import '../../theme/func_semantic_tokens.dart';

/// Minimum card width used to derive the masonry column count.
const _kMinCardExtent = 180.0;

/// How far beyond the viewport feed children are built and start resolving
/// their images.
///
/// A viewport multiplier keeps the look-ahead proportional to the device:
/// half a screen ahead is roughly two masonry rows, enough for a card's
/// request+decode to start before it is exposed without keeping a full
/// extra screen of image work alive during a fling.
const ScrollCacheExtent kFeedCacheExtent = ScrollCacheExtent.viewport(0.5);

/// Ordered work ids a pushed detail route can page through — the same
/// list the grid shows, handed over via `IllustRouteExtra.pagerSource`.
/// Opening a work from a feed keeps the
/// feed's ordering, so swiping sideways moves to the previous/next work
/// without returning to the grid.
///
/// The grid's State owns the instance so it survives rebuilds; [update]
/// is called whenever the feed publishes a new id list, and [onNearEnd]
/// is the feed's `loadMore` — the pager calls it when the user swipes
/// close to the end, which is how paged detail keeps growing.
class IllustPagerSource extends ChangeNotifier {
  List<int> _ids = const [];

  /// Work ids in feed order.
  List<int> get ids => _ids;

  /// Feed-side "fetch the next page" hook. Feeds without a continuation
  /// leave it null and the pager stops at the last work.
  VoidCallback? onNearEnd;

  /// Grids publish a fresh list on every rebuild — a load-more phase flip
  /// included — so only a changed order notifies: each notify re-seats the
  /// open pager.
  void update(List<int> ids) {
    if (identical(ids, _ids) || listEquals(ids, _ids)) return;
    _ids = List.unmodifiable(ids);
    notifyListeners();
  }
}

/// Exposes the enclosing grid's [IllustPagerSource] to the cards it
/// builds. The lookup is deliberately non-subscribing: a card only reads
/// the reference at tap time, so id-list churn must not rebuild cards.
class IllustPagerScope extends InheritedWidget {
  const IllustPagerScope({
    super.key,
    required this.source,
    required super.child,
  });

  final IllustPagerSource source;

  static IllustPagerSource? maybeOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<IllustPagerScope>();
    return element == null ? null : (element.widget as IllustPagerScope).source;
  }

  @override
  bool updateShouldNotify(IllustPagerScope oldWidget) =>
      source != oldWidget.source;
}

/// The resolved column width for feed children, published by
/// [IllustFeedGrid] so cards can size their preview + decode width without
/// a per-card [LayoutBuilder] (one less element and layout callback per
/// card mounted during a fling).
class FeedItemExtent extends InheritedWidget {
  const FeedItemExtent({super.key, required this.width, required super.child});

  /// The card's main-axis-unconstrained width in logical pixels.
  final double width;

  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FeedItemExtent>()?.width;

  @override
  bool updateShouldNotify(FeedItemExtent oldWidget) => width != oldWidget.width;
}

/// Column count for a masonry grid with the given cross-axis extent.
/// Phone widths stay at 2 columns (beta56 behaviour); wide and foldable
/// layouts add columns naturally. Never below 2.
int illustColumnsFor(double crossAxisExtent) {
  if (crossAxisExtent <= 0) return 2;
  return math.max(2, (crossAxisExtent / _kMinCardExtent).floor());
}

/// Shared masonry sliver used by every feed (recommended, ranking, new,
/// search, history, profile, related). Column count derives from the actual
/// cross-axis extent the sliver receives — under the wide NavigationRail the
/// content width is smaller than the window, so reading `MediaQuery` here
/// would over-count columns.
class IllustFeedGrid extends StatefulWidget {
  /// Feed defaults shared with [IllustGridSkeleton]: the skeleton reads
  /// these so a loading feed already occupies the same slots.
  static const defaultPadding = EdgeInsets.symmetric(
    horizontal: FuncSpacing.sm,
  );
  static const defaultMainAxisSpacing = FuncSpacing.xs;
  static const defaultCrossAxisSpacing = FuncSpacing.sm;

  const IllustFeedGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = defaultPadding,
    this.mainAxisSpacing = defaultMainAxisSpacing,
    this.crossAxisSpacing = defaultCrossAxisSpacing,
    this.itemIds,
    this.pagerLoadMore,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry padding;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  /// Stable entity ids aligned with [itemBuilder]'s index order. Supplying
  /// them does two things positional identity cannot: the staggered
  /// entrance marks entities (not slots) as played, and
  /// [SliverChildBuilderDelegate.findChildIndexCallback] re-seats element
  /// state when a refresh inserts at the head — without keys, every card's
  /// subtree is re-bound to whatever entity landed on its old position.
  /// They also become the detail pager's work list — opening a card lets
  /// the user swipe sideways through the feed.
  final List<int>? itemIds;

  /// Feed's next-page hook for the work-to-work detail pager: swiping
  /// near the list end calls it, so the paged detail keeps growing instead
  /// of stopping at the loaded edge. Finite lists
  /// leave it null.
  final VoidCallback? pagerLoadMore;

  @override
  State<IllustFeedGrid> createState() => _IllustFeedGridState();
}

class _IllustFeedGridState extends State<IllustFeedGrid> {
  /// Staggered-entrance entity ids already shown by this grid instance; the
  /// grid drops keep-alives, so without it a card scrolling back into view
  /// replays its entrance and reads as a reload.
  final _entrancePlayed = <int>{};

  /// Work ids + next-page hook for the detail pager. Never disposed by the
  /// grid: a pushed detail route still holds it — its lifetime is the
  /// route's, not the widget's.
  final _pagerSource = IllustPagerSource();

  @override
  void initState() {
    super.initState();
    _pagerSource
      ..onNearEnd = widget.pagerLoadMore
      ..update(widget.itemIds ?? const []);
    if (widget.itemCount > 0) requestContentFontPrefetch();
  }

  @override
  void didUpdateWidget(covariant IllustFeedGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pagerSource
      ..onNearEnd = widget.pagerLoadMore
      ..update(widget.itemIds ?? const []);
    // A page of new titles is about to be laid out.
    if (widget.itemCount > oldWidget.itemCount) requestContentFontPrefetch();
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.padding
        .resolve(Directionality.of(context))
        .horizontal;
    // SliverLayoutBuilder is called again when the scroll offset changes.
    // Keep the generated grid widget stable for the same width so its
    // SliverChildBuilderDelegate is not recreated on every scroll tick. A
    // width change still creates a new grid and recalculates the columns.
    double? cachedCrossAxisExtent;
    Widget? cachedGrid;
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final crossAxisExtent = constraints.crossAxisExtent;
        if (cachedGrid != null && cachedCrossAxisExtent == crossAxisExtent) {
          return cachedGrid!;
        }
        final columns = illustColumnsFor(crossAxisExtent - horizontal);
        final columnWidth =
            (crossAxisExtent -
                horizontal -
                (columns - 1) * widget.crossAxisSpacing) /
            columns;
        Widget grid = SliverPadding(
          padding: widget.padding,
          sliver: SliverMasonryGrid(
            gridDelegate: SliverSimpleGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
            ),
            mainAxisSpacing: widget.mainAxisSpacing,
            crossAxisSpacing: widget.crossAxisSpacing,
            // Feed cards are provider-backed/stateless. They do not own
            // scroll-position state, so the default AutomaticKeepAlive
            // wrapper only adds elements and notifications to every card.
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final ids = widget.itemIds;
                final id = ids != null && index < ids.length
                    ? ids[index]
                    : index;
                return FeedItemExtent(
                  width: columnWidth,
                  // Keyed by work: a slot taking a different work mounts
                  // afresh.
                  child: StaggeredEntrance(
                    key: ValueKey(id),
                    index: index,
                    id: id,
                    played: _entrancePlayed,
                    child: widget.itemBuilder(context, index),
                  ),
                );
              },
              childCount: widget.itemCount,
              addAutomaticKeepAlives: false,
              findChildIndexCallback: widget.itemIds == null
                  ? null
                  : (key) {
                      if (key is! ValueKey<int>) return null;
                      final i = widget.itemIds!.indexOf(key.value);
                      return i < 0 ? null : i;
                    },
            ),
          ),
        );
        // Cards inside a grid with stable ids get the feed's work list as
        // their detail-pager source — tapping one opens the swipeable
        // detail, grids without ids (spotlight rows etc.) leave cards on
        // the single-work route.
        if (widget.itemIds != null) {
          grid = IllustPagerScope(source: _pagerSource, child: grid);
        }
        cachedCrossAxisExtent = crossAxisExtent;
        cachedGrid = grid;
        return grid;
      },
    );
  }
}
