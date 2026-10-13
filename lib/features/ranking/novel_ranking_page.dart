import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/navigation/routes.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/novel_entry.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/network/api_date.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_ranking_feed_controller.dart';
import '../../core/novel/novel_repository.dart';
import '../../core/novel/novel_store.dart';
import '../../core/ranking/ranking_catalog.dart';
import '../../l10n/context.dart';
import 'ranking_tabs.dart';

/// The novel ranking, pushed from the illust ranking: [RankingTabs] over
/// the novel categories, each a list of ranked novels.
class NovelRankingPage extends StatelessWidget {
  const NovelRankingPage({
    super.key,
    this.initialMode,
    this.date,
    this.onRouteChanged,
  });

  /// The route's `?mode=`; null opens on the last category viewed.
  final NovelRankingMode? initialMode;

  /// The ranking day from the route; null is the latest.
  final DateTime? date;
  final RankingRouteChanged<NovelRankingMode>? onRouteChanged;

  @override
  Widget build(BuildContext context) {
    return RankingTabs<NovelRankingMode>(
      catalog: novelRankingCatalog,
      routeMode: initialMode,
      date: date,
      onRouteChanged: onRouteChanged,
      switchLabel: context.l10n.rankingIllust,
      switchIcon: Icons.image_outlined,
      onSwitch: openIllustRanking,
      bodyBuilder: (mode, date, scrollController) => _NovelRankingModeBody(
        feedKey: (mode: mode, date: date),
        scrollController: scrollController,
      ),
    );
  }
}

class _NovelRankingModeBody extends ConsumerWidget {
  const _NovelRankingModeBody({
    required this.feedKey,
    required this.scrollController,
  });

  final NovelRankingFeedKey feedKey;
  final ScrollController scrollController;

  /// Scroll restoration per list: a past day is a different list from the
  /// latest one.
  String get _listId => switch (feedKey.date) {
    null => feedKey.mode.name,
    final date => '${feedKey.mode.name}-${formatApiDate(date)}',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(novelRankingFeedProvider(feedKey));
    final store = ref.watch(novelStoreProvider);
    return state.when(
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: rankingLoadFailedTitle(context, feedKey.mode),
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () =>
            ref.read(novelRankingFeedProvider(feedKey).notifier).retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: rankingLoadFailedTitle(context, feedKey.mode),
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.retry,
            onRetry: () => ref
                .read(novelRankingFeedProvider(feedKey).notifier)
                .retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return const FeedLoading();
        }
        if (feed.isEmptyAndReady) {
          return rankingEmpty(
            context,
            feedKey.mode,
            () =>
                ref.read(novelRankingFeedProvider(feedKey).notifier).refresh(),
          );
        }

        final entities = [
          for (final id in feed.ids)
            if (store[id] != null) store[id]!,
        ];
        return PullToRefresh(
          onRefresh: () =>
              ref.read(novelRankingFeedProvider(feedKey).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification &&
                  notification.metrics.extentAfter <
                      notification.metrics.viewportDimension * 1.2) {
                ref.read(novelRankingFeedProvider(feedKey).notifier).loadMore();
              }
              return false;
            },
            child: SmoothWheelScroll(
              controller: scrollController,
              basePhysics: const AlwaysScrollableScrollPhysics(),
              builder: (context, controller, physics) => CustomScrollView(
                key: PageStorageKey('novel-ranking-$_listId'),
                controller: controller,
                physics: physics,
                scrollCacheExtent: kFeedCacheExtent,
                restorationId: 'novel-ranking-$_listId',
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.only(top: FuncSpacing.sm),
                    sliver: SliverList.builder(
                      itemCount: entities.length,
                      itemBuilder: (context, index) => KeyedSubtree(
                        key: ValueKey(entities[index].id),
                        child: NovelEntry.ranking(
                          entity: entities[index],
                          rank: index + 1,
                        ),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: FeedTail(
                      feed: feed,
                      onRetry: () => ref
                          .read(novelRankingFeedProvider(feedKey).notifier)
                          .retryLoadMore(),
                      errorTitle: context.l10n.rankingLoadMoreFailed,
                      retryLabel: context.l10n.retry,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
