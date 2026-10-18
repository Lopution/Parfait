import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../layout/sliver_width_builder.dart';
import '../../motion/motion_tokens.dart';
import '../../theme/func_semantic_tokens.dart';
import 'feed_text_warmup.dart';

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

  /// The grid's built cards by work id, for [aimHomeFlight].
  final _cards = <int, ({BuildContext context, VoidCallback rebuild})>{};

  /// The work whose card the pager's image must not fly back to.
  int? _grounded;

  void attachCard(int id, BuildContext context, VoidCallback rebuild) =>
      _cards[id] = (context: context, rebuild: rebuild);

  void detachCard(int id, BuildContext context) {
    if (identical(_cards[id]?.context, context)) _cards.remove(id);
  }

  /// Whether the card of [id] may take the image flying back from the
  /// pager.
  bool cardFlies(int id) => id != _grounded;

  /// Called by the pager as it turns to [id]: a back flight lands on the
  /// card only while some of it is on screen. Hero pairs by tag alone, so
  /// a card built in the cache extent off screen would otherwise pull the
  /// image off the edge (TRANS-09). Decided here, not at the pop: the back
  /// gesture collects its Heroes the moment it starts.
  void aimHomeFlight(int id) => _ground(_cardOnScreen(id) ? null : id);

  /// The pager closed: every card flies again.
  void clearHomeFlight() => _ground(null);

  void _ground(int? id) {
    if (id == _grounded) return;
    final previous = _grounded;
    _grounded = id;
    for (final changed in [previous, id]) {
      if (changed != null) _cards[changed]?.rebuild();
    }
  }

  bool _cardOnScreen(int id) {
    final card = _cards[id]?.context;
    final box = card?.findRenderObject();
    if (card == null || box is! RenderBox || !box.hasSize) return false;
    // Every enclosing scroll view clips the card: the feed, and a row or a
    // page it sits in.
    for (
      var scrollable = card.findAncestorStateOfType<ScrollableState>();
      scrollable != null;
      scrollable = scrollable.context.findAncestorStateOfType<ScrollableState>()
    ) {
      final viewport = scrollable.context.findRenderObject();
      if (viewport is! RenderBox || !viewport.hasSize) continue;
      final rect = MatrixUtils.transformRect(
        box.getTransformTo(viewport),
        Offset.zero & box.size,
      );
      if (!rect.overlaps(Offset.zero & viewport.size)) return false;
    }
    return true;
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

/// A work's card under an [IllustPagerScope]: it registers with the
/// scope's pager so the image flies back to it only while some of it is
/// on screen. Outside a scope it is [child] alone.
class IllustPagerAnchor extends StatefulWidget {
  const IllustPagerAnchor({
    super.key,
    required this.illustId,
    required this.child,
  });

  final int illustId;
  final Widget child;

  @override
  State<IllustPagerAnchor> createState() => _IllustPagerAnchorState();
}

class _IllustPagerAnchorState extends State<IllustPagerAnchor> {
  IllustPagerSource? _source;

  @override
  void initState() {
    super.initState();
    _source = IllustPagerScope.maybeOf(context)
      ?..attachCard(widget.illustId, context, _rebuild);
  }

  @override
  void didUpdateWidget(IllustPagerAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.illustId != oldWidget.illustId) {
      _source
        ?..detachCard(oldWidget.illustId, context)
        ..attachCard(widget.illustId, context, _rebuild);
    }
  }

  @override
  void dispose() {
    _source?.detachCard(widget.illustId, context);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) => switch (_source) {
    final source? => HeroMode(
      enabled: source.cardFlies(widget.illustId),
      child: widget.child,
    ),
    null => widget.child,
  };
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

/// The narrowest card and the fewest columns at each density: a phone
/// fits three, two or one, and wider layouts add columns in proportion.
({double minCardExtent, int minColumns}) _densityGrid(FeedDensity density) =>
    switch (density) {
      FeedDensity.compact => (minCardExtent: 120, minColumns: 3),
      FeedDensity.standard => (minCardExtent: 180, minColumns: 2),
      FeedDensity.comfortable => (minCardExtent: 360, minColumns: 1),
    };

/// Column count for a masonry grid with the given cross-axis extent at
/// [density].
int illustColumnsFor(double crossAxisExtent, FeedDensity density) {
  final grid = _densityGrid(density);
  if (crossAxisExtent <= 0) return grid.minColumns;
  return math.max(
    grid.minColumns,
    (crossAxisExtent / grid.minCardExtent).floor(),
  );
}

/// Shared masonry sliver used by every feed (recommended, ranking, new,
/// search, history, profile, related). Column count derives from the actual
/// cross-axis extent the sliver receives — under the wide NavigationRail the
/// content width is smaller than the window, so reading `MediaQuery` here
/// would over-count columns.
class IllustFeedGrid extends ConsumerStatefulWidget {
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
    this.warmTexts,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry padding;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  /// Stable entity ids aligned with [itemBuilder]'s index order. Supplying
  /// them does two things positional identity cannot: the staggered
  /// entrance marks entities (not slots) as played, and
  /// keys the card subtree so a refresh mounts a new card when an entity
  /// changes position — without keys, every card's subtree is re-bound to
  /// whatever entity landed on its old position.
  /// They also become the detail pager's work list — opening a card lets
  /// the user swipe sideways through the feed.
  final List<int>? itemIds;

  /// Feed's next-page hook for the work-to-work detail pager: swiping
  /// near the list end calls it, so the paged detail keeps growing instead
  /// of stopping at the loaded edge. Finite lists
  /// leave it null.
  final VoidCallback? pagerLoadMore;

  /// The text lines of the card at an index, as the card lays them out
  /// (`IllustCard.warmTexts`). New items' lines are laid out between frames
  /// before their cards are built ([FeedTextWarmup]).
  final List<WarmText> Function(BuildContext context, int index)? warmTexts;

  @override
  ConsumerState<IllustFeedGrid> createState() => _IllustFeedGridState();
}

class _IllustFeedGridState extends ConsumerState<IllustFeedGrid> {
  /// Work ids + next-page hook for the detail pager. Never disposed by the
  /// grid: a pushed detail route still holds it — its lifetime is the
  /// route's, not the widget's.
  final _pagerSource = IllustPagerSource();

  final _warmup = FeedTextWarmup();
  int _warmedCount = 0;
  int? _warmedHead;

  @override
  void initState() {
    super.initState();
    _pagerSource
      ..onNearEnd = widget.pagerLoadMore
      ..update(widget.itemIds ?? const []);
  }

  @override
  void didUpdateWidget(covariant IllustFeedGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pagerSource
      ..onNearEnd = widget.pagerLoadMore
      ..update(widget.itemIds ?? const []);
  }

  @override
  void dispose() {
    _warmup.dispose();
    super.dispose();
  }

  /// Queues the lines of items not queued yet; a feed whose head changed
  /// (a refresh) starts over.
  void _queueWarmup(BuildContext context) {
    final warmTexts = widget.warmTexts;
    if (warmTexts == null) return;
    final head = widget.itemIds?.firstOrNull;
    if (head != _warmedHead || widget.itemCount < _warmedCount) {
      _warmup.clear();
      _warmedCount = 0;
      _warmedHead = head;
    }
    if (widget.itemCount == _warmedCount) return;
    _warmup.add(
      [
        for (var i = _warmedCount; i < widget.itemCount; i++)
          ...warmTexts(context, i),
      ],
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
    );
    _warmedCount = widget.itemCount;
  }

  @override
  Widget build(BuildContext context) {
    _queueWarmup(context);
    final density = ref.watch(feedDensityProvider);
    final horizontal = widget.padding
        .resolve(Directionality.of(context))
        .horizontal;
    return SliverWidthBuilder(
      builder: (context, crossAxisExtent) {
        final columns = illustColumnsFor(crossAxisExtent - horizontal, density);
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
                // Keyed by work: a slot taking a different work mounts
                // afresh. Cards land in place, as in Shaft; only their
                // images fade in.
                return FeedItemExtent(
                  width: columnWidth,
                  child: TickerPartition(
                    key: ValueKey(id),
                    child: widget.itemBuilder(context, index),
                  ),
                );
              },
              childCount: widget.itemCount,
              addAutomaticKeepAlives: false,
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
        return grid;
      },
    );
  }
}
