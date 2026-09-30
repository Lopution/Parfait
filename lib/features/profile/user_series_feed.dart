import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_refresh/easy_refresh.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../app/navigation/routes.dart';
import '../../app/pixiv_image.dart';
import '../../core/network/api_error.dart';
import '../../core/series/series_feed_controller.dart';
import '../../core/series/series_models.dart';
import '../../core/series/series_store.dart';
import '../../l10n/context.dart';
import 'profile_work_type_switch.dart';
import '../../app/theme/func_semantic_tokens.dart';

/// Profile work-tab section: the user's public illust series as a card
/// grid (`/v1/user/illust-series`). Mounted inside the profile
/// NestedScrollView, so it keeps the HeaderLocator/isNested contract of the
/// sibling work feeds.
/// Grid padding and spacing shared by this feed and its first-load
/// skeleton.
const _gridPadding = EdgeInsets.all(FuncSpacing.sm);
const _gridMainAxisSpacing = FuncSpacing.sm;

class UserSeriesFeed extends ConsumerWidget {
  const UserSeriesFeed({super.key, required this.userId, this.typeSwitch});

  final int userId;

  /// Work tab only: the compact section selector this feed hosts (D3).
  final ProfileWorkTypeSwitch? typeSwitch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userSeriesFeedProvider(userId));
    final typeSwitch = this.typeSwitch;
    Widget wrapState(Widget state) =>
        typeSwitch?.aboveState(context, state) ?? state;
    return async.when(
      loading: () => wrapState(
        IllustGridSkeleton(
          label: context.l10n.contentLoading,
          padding: _gridPadding,
          mainAxisSpacing: _gridMainAxisSpacing,
        ),
      ),
      error: (error, _) => wrapState(
        FeedError(
          title: context.l10n.seriesLoadFailed,
          error: error,
          retryLabel: context.l10n.retry,
          onRetry: () =>
              ref.read(userSeriesFeedProvider(userId).notifier).retryInitial(),
        ),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return wrapState(
            FeedError(
              title: context.l10n.seriesLoadFailed,
              error: feed.initialError ?? const ApiParseError('unknown error'),
              retryLabel: context.l10n.retry,
              onRetry: () => ref
                  .read(userSeriesFeedProvider(userId).notifier)
                  .retryInitial(),
            ),
          );
        }
        if (feed.showInitialSpinner) {
          return wrapState(
            IllustGridSkeleton(
              label: context.l10n.contentLoading,
              padding: _gridPadding,
              mainAxisSpacing: _gridMainAxisSpacing,
            ),
          );
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
                if (typeSwitch != null) typeSwitch.sliver(context),
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
                    padding: _gridPadding,
                    mainAxisSpacing: _gridMainAxisSpacing,
                    itemIds: [for (final e in entities) e.id],
                    itemCount: entities.length,
                    itemBuilder: (context, index) =>
                        _UserSeriesCardView(series: entities[index]),
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

class _UserSeriesCardView extends StatelessWidget {
  const _UserSeriesCardView({required this.series});

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
              padding: const EdgeInsets.fromLTRB(
                FuncSpacing.sm,
                FuncSpacing.xs,
                FuncSpacing.sm,
                FuncSpacing.sm,
              ),
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
