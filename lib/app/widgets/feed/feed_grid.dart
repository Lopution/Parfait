import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/network/compat/network_providers.dart';
import '../../../core/settings/settings_controller.dart';
import '../../image_tier_cache.dart';
import '../../motion/feed_entrance.dart';
import '../../pixiv_image.dart';

/// Minimum card width used to derive the masonry column count.
const _kMinCardExtent = 180.0;

/// How far beyond the viewport feed children are built and start resolving
/// their images.
///
/// A viewport multiplier keeps the look-ahead proportional to the device:
/// half a screen ahead is roughly two masonry rows, enough for a card's
/// request+decode to start before it is exposed without keeping a full
/// extra screen of image work alive during a fling. The rows beyond it are
/// covered by [scheduleFeedPreviewPrefetch], which runs at data arrival
/// instead of layout time.
const ScrollCacheExtent kFeedCacheExtent = ScrollCacheExtent.viewport(0.5);

/// How many items past the built edge each prefetch step warms.
const int _kFeedPrefetchAhead = 12;

/// Concurrent preview resolves admitted per prefetch batch.
const int _kFeedPrefetchConcurrent = 4;

/// (url, decodeWidth) pairs already issued. Bounded LRU so a long session
/// does not grow the set without limit.
final LinkedHashSet<String> _feedPrefetched = LinkedHashSet<String>();

/// Warms the decode+HTTP cache for feed items just past the built edge.
///
/// `cacheExtent` only ever builds a fraction of a viewport ahead, so a
/// card's image request still starts when the card is nearly exposed. The
/// entities are already known once a feed page lands — resolving their
/// preview URLs here moves network+decode off the scroll path entirely.
/// The entry is the exact key the card resolves (preview tier, card-width
/// decode), so an already-painted card is a no-op and a prefetched card
/// appears instantly.
///
/// The same rule `ScrollAwareImageProvider` applies to the cards is kept
/// here: a fling admits no new image work. Instead of timers the loop
/// awaits the scroll position's isScrolling notifier, then gives up to the
/// next watermark advance if the user is still flinging.
void scheduleFeedPreviewPrefetch(
  BuildContext context,
  List<IllustEntity> entities,
  int fromIndex,
  int decodeWidth,
) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    unawaited(_prefetchFeedWindow(context, entities, fromIndex, decodeWidth));
  });
}

Future<void> _prefetchFeedWindow(
  BuildContext context,
  List<IllustEntity> entities,
  int fromIndex,
  int decodeWidth,
) async {
  final ProviderContainer container;
  try {
    container = ProviderScope.containerOf(context, listen: false);
  } on StateError {
    // Tests and embedders without the app scope have no network factory —
    // prefetch is best-effort, so skip rather than fail an unawaited path.
    return;
  }
  final cacheManager = container
      .read(pixivNetworkFactoryProvider)
      .imageCacheManager;
  final previewQuality = container.read(previewQualityProvider);
  final end = math.min(entities.length, fromIndex + _kFeedPrefetchAhead);
  for (var i = fromIndex; i < end; i += _kFeedPrefetchConcurrent) {
    if (!context.mounted) return;
    if (_isDeferred(context)) {
      await _waitForScrollIdle(context);
      if (!context.mounted || _isDeferred(context)) {
        // Still moving fast — the next built-edge advance reschedules.
        return;
      }
    }
    final batch = <Future<void>>[];
    for (var j = i; j < math.min(i + _kFeedPrefetchConcurrent, end); j++) {
      final entity = entities[j];
      if (!entity.visible) continue;
      final url = entity.previewUrl(previewQuality);
      if (!_feedPrefetched.add('$url|$decodeWidth')) continue;
      while (_feedPrefetched.length > 512) {
        _feedPrefetched.remove(_feedPrefetched.first);
      }
      batch.add(
        PixivImage.preload(
          context,
          url,
          cacheManager: cacheManager,
          tierKey: entity.imageTierKeyAt(0),
          tier: previewQuality.tier,
          memCacheWidth: decodeWidth,
        ),
      );
    }
    if (batch.isNotEmpty) {
      // A context that unmounted mid-push makes precacheImage throw —
      // prefetch is best-effort, so a failed batch never propagates.
      try {
        await Future.wait(batch);
      } on Object {
        return;
      }
    }
  }
}

/// [Scrollable.recommendDeferredLoadingForContext] throws on an element
/// that unmounted mid-await — treat that as "no longer scrolling".
bool _isDeferred(BuildContext context) {
  try {
    return Scrollable.recommendDeferredLoadingForContext(context);
  } on Object {
    return false;
  }
}

/// Resolves when the enclosing [Scrollable] reports it is no longer
/// scrolling. If the scrollable is already idle (or gone) this completes
/// immediately; an unmounted scrollable never completes, which is fine —
/// the suspended future is collected with the caller's frame.
Future<void> _waitForScrollIdle(BuildContext context) {
  final ScrollableState? scrollable;
  try {
    scrollable = Scrollable.maybeOf(context);
  } on Object {
    return Future<void>.value();
  }
  final notifier = scrollable?.position.isScrollingNotifier;
  if (notifier == null || !notifier.value) {
    return Future<void>.value();
  }
  final completer = Completer<void>();
  void listener() {
    if (notifier.value) return;
    notifier.removeListener(listener);
    completer.complete();
  }

  notifier.addListener(listener);
  return completer.future;
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

/// Tracks the most recently built feed index and turns each new build
/// into the window start a prefetch should warm.
///
/// An advancing build warms the window right after the built edge (the
/// original watermark behaviour). A lower build is a scroll-back or a
/// re-advance below the old mark: decoded entries for the rows above the
/// revealed card were likely evicted during the fling, so the window
/// *above* it is warmed instead — the re-decode then happens off the
/// scroll path rather than flashing placeholders when the scroll settles.
/// Repeating the same index schedules nothing.
class FeedPrefetchCursor {
  int _last = -1;

  /// The window start for [index], or null when nothing should be warmed.
  int? advance(int index, {required int ahead}) {
    if (index == _last) return null;
    final from = index > _last ? index + 1 : math.max(0, index - ahead);
    _last = index;
    return from;
  }
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
  const IllustFeedGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
    this.mainAxisSpacing = 5,
    this.crossAxisSpacing = 10,
    this.prefetchEntities,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry padding;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  /// When set, the grid warms preview images for entities just past the
  /// built edge as it advances — the bounded off-screen preload that a bare
  /// cacheExtent cannot express. Leave unset for non-feed grids.
  final List<IllustEntity>? prefetchEntities;

  @override
  State<IllustFeedGrid> createState() => _IllustFeedGridState();
}

class _IllustFeedGridState extends State<IllustFeedGrid> {
  /// Staggered-entrance indices already shown by this grid instance; the
  /// grid drops keep-alives, so without it a card scrolling back into view
  /// replays its entrance and reads as a reload.
  final _entrancePlayed = <int>{};

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
    final prefetchCursor = FeedPrefetchCursor();
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
        final decodeWidth = PixivImage.decodeWidthFor(columnWidth);
        final grid = SliverPadding(
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
                final prefetch = widget.prefetchEntities;
                if (prefetch != null) {
                  final from = prefetchCursor.advance(
                    index,
                    ahead: _kFeedPrefetchAhead,
                  );
                  if (from != null) {
                    scheduleFeedPreviewPrefetch(
                      context,
                      prefetch,
                      from,
                      decodeWidth,
                    );
                  }
                }
                return FeedItemExtent(
                  width: columnWidth,
                  child: StaggeredEntrance(
                    index: index,
                    played: _entrancePlayed,
                    child: widget.itemBuilder(context, index),
                  ),
                );
              },
              childCount: widget.itemCount,
              addAutomaticKeepAlives: false,
            ),
          ),
        );
        cachedCrossAxisExtent = crossAxisExtent;
        cachedGrid = grid;
        return grid;
      },
    );
  }
}
