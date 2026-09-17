import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_refresh/easy_refresh.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/navigation/routes.dart';
import '../../app/pixiv_image.dart';
import '../../core/network/api_error.dart';
import '../../core/series/series_feed_controller.dart';
import '../../core/series/series_models.dart';
import '../../core/series/series_store.dart';
import '../../l10n/context.dart';

/// Profile work-tab section: the user's public illust series as a card
/// grid (`/v1/user/illust-series`). Mounted inside the profile
/// NestedScrollView, so it keeps the HeaderLocator/isNested contract of the
/// sibling work feeds.
class UserSeriesFeed extends ConsumerWidget {
  const UserSeriesFeed({super.key, required this.userId});

  final int userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userSeriesFeedProvider(userId));
    return async.when(
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: context.l10n.seriesLoadFailed,
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () =>
            ref.read(userSeriesFeedProvider(userId).notifier).retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: context.l10n.seriesLoadFailed,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.retry,
            onRetry: () => ref
                .read(userSeriesFeedProvider(userId).notifier)
                .retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return const FeedLoading();
        }
        final store = ref.watch(illustSeriesStoreProvider);
        final entities = [
          for (final id in feed.ids)
            if (store[id] != null) store[id]!,
        ];
        return PullToRefresh(
          isNested: true,
          onRefresh: () =>
              ref.read(userSeriesFeedProvider(userId).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.axis == Axis.vertical &&
                  notification is ScrollUpdateNotification &&
                  notification.metrics.extentAfter <
                      notification.metrics.viewportDimension * 1.2) {
                ref.read(userSeriesFeedProvider(userId).notifier).loadMore();
              }
              return false;
            },
            child: CustomScrollView(
              key: PageStorageKey('user-series-$userId'),
              restorationId: 'user-series-$userId',
              physics: const AlwaysScrollableScrollPhysics(),
              scrollCacheExtent: kFeedCacheExtent,
              slivers: [
                const HeaderLocator.sliver(),
                if (entities.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: FeedEmpty(
                      icon: Icons.collections_bookmark_outlined,
                      title: context.l10n.profileItemsEmpty,
                      retryLabel: context.l10n.retry,
                      onRefresh: () => ref
                          .read(userSeriesFeedProvider(userId).notifier)
                          .refresh(),
                    ),
                  )
                else
                  IllustFeedGrid(
                    padding: const EdgeInsets.all(10),
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 10,
                    itemCount: entities.length,
                    itemBuilder: (context, index) =>
                        _UserSeriesCard(series: entities[index]),
                  ),
                SliverToBoxAdapter(
                  child: FeedTail(
                    feed: feed,
                    onRetry: () => ref
                        .read(userSeriesFeedProvider(userId).notifier)
                        .retryLoadMore(),
                    errorTitle: context.l10n.seriesLoadMoreFailed,
                    retryLabel: context.l10n.retry,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _UserSeriesCard extends StatelessWidget {
  const _UserSeriesCard({required this.series});

  final IllustSeriesEntity series;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = series.coverUrl;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => openIllustSeries(context, series.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cover != null)
              AspectRatio(
                aspectRatio: 1.4,
                child: PixivImage.feed(
                  cover,
                  layoutWidth: FeedItemExtent.maybeOf(context) ?? 180,
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    series.title,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (series.workCount != null)
                    Text(
                      context.l10n.seriesWorksCount(series.workCount!),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
