import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/navigation/routes.dart';
import '../../app/pixiv_image.dart';
import '../../core/auth/account_store.dart';
import '../../core/entity/illust_store.dart';
import '../../core/network/api_error.dart';
import '../../core/series/series_feed_controller.dart';
import '../../core/series/series_models.dart';
import '../../core/series/series_store.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../app/widgets/watchlist_toggle.dart';
import '../../l10n/context.dart';

/// One illust series: a header (cover/title/author/work count/caption) plus
/// the paginated works grid (`/v1/illust/series`, newest first).
class IllustSeriesPage extends ConsumerWidget {
  const IllustSeriesPage({super.key, required this.seriesId});

  final int seriesId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(illustSeriesFeedProvider(seriesId));
    final detail = ref.watch(illustSeriesStoreProvider)[seriesId];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          detail?.title ?? context.l10n.seriesTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: async.when(
        loading: () => const FeedLoading(),
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
            return const FeedLoading();
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
                        padding: const EdgeInsets.all(10),
                        mainAxisSpacing: 5,
                        crossAxisSpacing: 10,
                        prefetchEntities: entities,
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
    // Opening the series marks the watchlist "new content" cursor at the
    // newest work the page knows about.
    final latest = detail.latestContentId;
    if (latest != null) {
      final accountId = ref.watch(
        accountStoreProvider.select((async) => async.value?.usableCurrent?.id),
      );
      if (accountId != null) {
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
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cover != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: PixivImage(
                    url: cover,
                    width: 88,
                    height: 88,
                    memCacheWidth: PixivImage.decodeWidthFor(88),
                  ),
                ),
              if (cover != null) const SizedBox(width: 12),
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
                    const SizedBox(height: 4),
                    InkWell(
                      onTap: () => openUser(context, detail.userId),
                      child: Text(
                        detail.userName,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
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
          const SizedBox(height: 10),
          WatchlistToggle(
            seriesKey: WatchlistKey(WatchlistType.manga, detail.id),
            detailAdded: detail.watchlistAdded,
          ),
          if (detail.caption.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(detail.caption, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
