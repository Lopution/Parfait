import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../layout/form_factor.dart';
import '../../layout/sliver_cache_ramp.dart';
import '../../layout/sliver_width_builder.dart';
import '../../motion/motion_tokens.dart';
import '../../theme/func_semantic_tokens.dart';
import 'feed_item_cache.dart';
import 'feed_selection.dart';
import 'feed_text_warmup.dart';
import 'illust_pager_source.dart';

/// How far beyond the viewport feed children are built and start resolving
/// their images.
///
/// A viewport multiplier keeps the look-ahead proportional to the device:
/// half a screen ahead is roughly two masonry rows, enough for a card's
/// request+decode to start before it is exposed without keeping a full
/// extra screen of image work alive during a fling.
const ScrollCacheExtent kFeedCacheExtent = ScrollCacheExtent.viewport(0.5);

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

/// Desktop (`FormFactor.pc`) column ladder: wider card extents across all
/// three densities so 1280px–1440px monitors step cleanly (~4/5/6 columns)
/// without collapsing `compact` into cramped 10-column strips.
({double minCardExtent, int minColumns}) _pcDensityGrid(FeedDensity density) =>
    switch (density) {
      FeedDensity.compact => (minCardExtent: 176, minColumns: 3),
      FeedDensity.standard => (minCardExtent: 204, minColumns: 2),
      FeedDensity.comfortable => (minCardExtent: 268, minColumns: 1),
    };

/// Column count for a masonry grid with the given cross-axis extent at
/// [density]. On desktop (`FormFactor.pc`) all three densities use balanced
/// desktop card extents ([_pcDensityGrid]) while mobile/tablet viewports keep
/// [illustColumnsFor] unchanged.
int illustColumnsForContext(
  BuildContext context,
  double crossAxisExtent,
  FeedDensity density,
) {
  if (FormFactor.of(context) == FormFactor.pc) {
    final grid = _pcDensityGrid(density);
    if (crossAxisExtent <= 0) return grid.minColumns;
    return math.max(
      grid.minColumns,
      (crossAxisExtent / grid.minCardExtent).floor(),
    );
  }
  return illustColumnsFor(crossAxisExtent, density);
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
    horizontal: FuncSpacing.lg - FuncSpacing.xxs,
  );
  static const defaultMainAxisSpacing = 12.0;
  static const defaultCrossAxisSpacing = 12.0;

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
    this.items,
    this.itemDeps,
  }) : assert(items == null || items.length == itemCount);

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry padding;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  /// Stable entity ids aligned with [itemBuilder]'s index order.
  final List<int>? itemIds;

  /// Feed's next-page hook for the work-to-work detail pager: swiping
  /// near the list end calls it, so the paged detail keeps growing instead
  /// of stopping at the loaded edge. Finite lists
  /// leave it null.
  final VoidCallback? pagerLoadMore;

  /// The text lines of the card at an index, as the card lays them out
  /// (`IllustCard.warmTexts`). The lines of the cards just past the built
  /// ones are laid out between frames before those cards are built
  /// ([FeedTextWindow]).
  final WarmTexts? warmTexts;

  /// The entity behind each card. A built card is reused while its entity
  /// is the same instance and [itemDeps] stay equal ([FeedItemCache]).
  final List<Object>? items;

  /// Everything else [itemBuilder] reads, for [items].
  final Object? itemDeps;

  @override
  ConsumerState<IllustFeedGrid> createState() => _IllustFeedGridState();
}

class _IllustFeedGridState extends ConsumerState<IllustFeedGrid> {
  /// Work ids + next-page hook for the detail pager. Never disposed by the
  /// grid: a pushed detail route still holds it — its lifetime is the
  /// route's, not the widget's.
  final _pagerSource = IllustPagerSource();

  final _warmup = FeedTextWindow();
  final _cards = FeedItemCache();

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

  @override
  Widget build(BuildContext context) {
    final warmTexts = widget.warmTexts;
    if (warmTexts != null) {
      _warmup.update(
        context,
        count: widget.itemCount,
        head: widget.itemIds?.firstOrNull,
        texts: warmTexts,
      );
    }
    _cards.update(widget.items, widget.itemDeps);
    final selection = FeedSelectionScope.maybeOf(context);
    if (selection != null && widget.items != null) {
      selection.syncItems([
        for (final item in widget.items!)
          if (item is IllustEntity) item,
      ]);
    }
    final density = ref.watch(feedDensityProvider);
    final horizontal = widget.padding
        .resolve(Directionality.of(context))
        .horizontal;
    return SliverWidthBuilder(
      builder: (context, crossAxisExtent) {
        final columns = illustColumnsForContext(
          context,
          crossAxisExtent - horizontal,
          density,
        );
        final columnWidth =
            (crossAxisExtent -
                horizontal -
                (columns - 1) * widget.crossAxisSpacing) /
            columns;
        Widget grid = SliverPadding(
          padding: widget.padding,
          sliver: SliverCacheRamp(
            // Key by column count so cross-column resizes mount a fresh
            // SliverMasonryGrid instead of hitting flutter_staggered_grid_view
            // 0.7.0's in-place relayout bug (trailing child with null
            // layoutOffset / out-of-range crossAxisIndex).
            sliver: SliverMasonryGrid(
              key: ValueKey(columns),
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
                  if (widget.warmTexts != null) _warmup.built(context, index);
                  final ids = widget.itemIds;
                  final rawItem =
                      widget.items != null && index < widget.items!.length
                      ? widget.items![index]
                      : null;
                  final entityId = ids != null && index < ids.length
                      ? ids[index]
                      : (rawItem is IllustEntity ? rawItem.id : null);
                  final id = entityId ?? index;
                  Widget card = _cards.build(
                    context,
                    index,
                    widget.itemBuilder,
                  );
                  if (selection != null && entityId != null) {
                    card = FeedSelectableCardDecorator(
                      entityId: entityId,
                      child: card,
                    );
                  }
                  // Keyed by work: a slot taking a different work mounts
                  // afresh. Cards land in place, as in Shaft; only their
                  // images fade in.
                  return FeedItemExtent(
                    width: columnWidth,
                    child: TickerPartition(key: ValueKey(id), child: card),
                  );
                },
                childCount: widget.itemCount,
                addAutomaticKeepAlives: false,
              ),
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
