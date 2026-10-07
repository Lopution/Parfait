import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/navigation/routes.dart';
import '../../app/pixiv_image.dart';
import '../../app/widgets/author_row.dart';
import '../../app/widgets/expandable_text.dart';
import '../../core/auth/account_store.dart';
import '../../core/entity/illust_store.dart';
import '../../core/network/api_error.dart';
import '../../core/series/series_feed_controller.dart';
import '../../core/series/series_models.dart';
import '../../core/series/series_recent_open_store.dart';
import '../../core/series/series_store.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../app/widgets/watchlist_toggle.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';

/// One illust series: a header (cover/title/author/work count/caption) plus
/// the paginated works grid (`/v1/illust/series`, newest first).
/// Grid padding shared by the works sliver and its first-load skeleton.
const _gridPadding = EdgeInsets.all(FuncSpacing.sm);

class IllustSeriesPage extends ConsumerWidget {
  const IllustSeriesPage({super.key, required this.seriesId});

  final int seriesId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(illustSeriesFeedProvider(seriesId));
    final detail = ref.watch(illustSeriesStoreProvider)[seriesId];
    return Scaffold(
      appBar: AppTopBar(
        title: Text(
          detail?.title ?? context.l10n.seriesTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: async.when(
        loading: () => IllustGridSkeleton(
          label: context.l10n.contentLoading,
          padding: _gridPadding,
        ),
        error: (error, _) => FeedError(
          title: context.l10n.seriesLoadFailed,
          error: error,
          retryLabel: context.l10n.retry,
          onRetry: () => ref
              .read(illustSeriesFeedProvider(seriesId).notifier)
              .retryInitial(),
        ),
        data: (feed) {
          if (feed.showInitialError) {
            return FeedError(
              title: context.l10n.seriesLoadFailed,
              error: feed.initialError ?? const ApiParseError('unknown error'),
              retryLabel: context.l10n.retry,
              onRetry: () => ref
                  .read(illustSeriesFeedProvider(seriesId).notifier)
                  .retryInitial(),
            );
          }
          if (feed.showInitialSpinner) {
            return IllustGridSkeleton(
              label: context.l10n.contentLoading,
              padding: _gridPadding,
            );
          }
          final entities = ref.watch(illustStoreProvider).getAll(feed.ids);
          return PullToRefresh(
            onRefresh: () =>
                ref.read(illustSeriesFeedProvider(seriesId).notifier).refresh(),
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                // Same -500px threshold as the detail page's related works:
                // loadMore is internally guarded against re-entry and the
                // exhausted state.
                final metrics = notification.metrics;
                if (metrics.maxScrollExtent > 0 &&
                    metrics.pixels >= metrics.maxScrollExtent - 500) {
                  ref
                      .read(illustSeriesFeedProvider(seriesId).notifier)
                      .loadMore();
                }
                return false;
              },
              child: SmoothWheelScroll(
                basePhysics: const AlwaysScrollableScrollPhysics(),
                builder: (context, controller, physics) => CustomScrollView(
                  key: PageStorageKey('series-$seriesId'),
                  physics: physics,
                  scrollCacheExtent: kFeedCacheExtent,
                  restorationId: 'series-$seriesId',
                  controller: controller,
                  slivers: [
                    if (detail != null)
                      SliverToBoxAdapter(child: _SeriesHeader(detail: detail)),
                    if (entities.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: FeedEmpty(
                          icon: Icons.collections_bookmark_outlined,
                          title: context.l10n.seriesEmpty,
                          retryLabel: context.l10n.retry,
                          onRefresh: () => ref
                              .read(illustSeriesFeedProvider(seriesId).notifier)
                              .refresh(),
                        ),
                      )
                    else
                      IllustFeedGrid(
                        padding: _gridPadding,
                        itemIds: [for (final e in entities) e.id],
                        itemCount: entities.length,
                        itemBuilder: (context, index) => IllustCard(
                          entity: entities[index],
                          heroScope: 'series:$seriesId',
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: FeedTail(
                        feed: feed,
                        onRetry: () => ref
                            .read(illustSeriesFeedProvider(seriesId).notifier)
                            .retryLoadMore(),
                        errorTitle: context.l10n.seriesLoadMoreFailed,
                        retryLabel: context.l10n.retry,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SeriesHeader extends ConsumerWidget {
  const _SeriesHeader({required this.detail});

  final IllustSeriesEntity detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cover = detail.coverUrl;
    final accountId = ref.watch(
      accountStoreProvider.select((async) => async.value?.usableCurrent?.id),
    );
    // Opening the series marks the watchlist "new content" cursor at the
    // newest work the page knows about.
    final latest = detail.latestContentId;
    if (latest != null && accountId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(watchlistReadCursorProvider)
            .markSeen(
              accountId,
              WatchlistKey(WatchlistType.manga, detail.id),
              latest,
            );
      });
    }
    // 「继续第 n 话」honest variant: only what the session memory recorded —
    // this is a different state source than the markSeen cursor above (W4
    // gate: the two must not share one store).
    final recentOpenMap = ref.watch(seriesRecentOpenStoreProvider);
    final recent = accountId == null
        ? null
        : recentOpenMap[SeriesRecentOpenStore.keyFor(accountId, detail.id)];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.lg,
        FuncSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cover != null)
                ClipRRect(
                  borderRadius: FuncShape.control,
                  child: PixivImage(
                    url: cover,
                    width: 88,
                    height: 88,
                    memCacheWidth: PixivImage.decodeWidthFor(88),
                  ),
                ),
              if (cover != null) const SizedBox(width: FuncSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detail.title,
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    AuthorRow(userId: detail.userId, name: detail.userName),
                    if (detail.workCount != null)
                      Text(
                        context.l10n.seriesWorksCount(detail.workCount!),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: FuncSpacing.sm),
          WatchlistToggle(
            seriesKey: WatchlistKey(WatchlistType.manga, detail.id),
            detailAdded: detail.watchlistAdded,
          ),
          if (detail.firstContentId != null || recent != null) ...[
            const SizedBox(height: FuncSpacing.sm),
            _ReadingActions(
              firstContentId: detail.firstContentId,
              recent: recent,
            ),
          ],
          if (detail.caption.isNotEmpty) ...[
            const SizedBox(height: FuncSpacing.sm),
            ExpandableText(
              TextSpan(text: detail.caption),
              maxLines: 3,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// One primary way into the series. With a reading record (this session's
/// last opened work) it continues there, and starting over from the first
/// episode is the quieter second choice; without one it starts at the
/// first episode.
class _ReadingActions extends ConsumerWidget {
  const _ReadingActions({required this.firstContentId, required this.recent});

  /// Parsed from `illust_series_first_illust`; null when pixiv omits it.
  final int? firstContentId;
  final SeriesRecentOpenEntry? recent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void open(int illustId) => openIllust(
      context,
      illustId,
      initialEntity: ref.read(illustStoreProvider).get(illustId),
    );
    final recent = this.recent;
    final first = firstContentId;
    if (recent == null) {
      if (first == null) return const SizedBox.shrink();
      return FilledButton.icon(
        onPressed: () => open(first),
        icon: const Icon(Icons.play_arrow),
        label: Text(context.l10n.seriesStartReading),
      );
    }
    final order = recent.contentOrder;
    return OverflowBar(
      spacing: FuncSpacing.sm,
      overflowSpacing: FuncSpacing.xs,
      children: [
        FilledButton.icon(
          onPressed: () => open(recent.illustId),
          icon: const Icon(Icons.play_arrow),
          label: Text(
            order == null
                ? context.l10n.seriesContinue
                : context.l10n.seriesContinueEpisode(order),
          ),
        ),
        if (first != null)
          TextButton(
            onPressed: () => open(first),
            child: Text(context.l10n.seriesStartFromFirst),
          ),
      ],
    );
  }
}
