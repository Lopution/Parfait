import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/layout/deferred_cache_scroll_view.dart';
import '../../app/navigation/routes.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/entity/illust_store.dart';
import '../../core/illust/ranking_feed_controller.dart';
import '../../core/illust/ranking_repository.dart';
import '../../core/network/api_date.dart';
import '../../core/network/api_error.dart';
import '../../core/ranking/ranking_catalog.dart';
import '../../l10n/context.dart';
import 'ranking_tabs.dart';
import '../../app/widgets/feed/load_more_listener.dart';

/// The illust ranking, a home branch root: [RankingTabs] over the illust
/// categories, each a grid of ranked works.
class RankingPage extends StatelessWidget {
  const RankingPage({
    super.key,
    this.initialMode,
    this.date,
    this.onRouteChanged,
  });

  /// The route's `?mode=`; null opens on the last category viewed.
  final RankingMode? initialMode;

  /// The ranking day from the route; null is the latest.
  final DateTime? date;
  final RankingRouteChanged<RankingMode>? onRouteChanged;

  @override
  Widget build(BuildContext context) {
    return RankingTabs<RankingMode>(
      catalog: illustRankingCatalog,
      routeMode: initialMode,
      date: date,
      onRouteChanged: onRouteChanged,
      switchLabel: context.l10n.novelRanking,
      switchIcon: Icons.menu_book_outlined,
      onSwitch: openNovelRanking,
      bodyBuilder: (mode, date, scrollController) => _RankingModeBody(
        feedKey: (mode: mode, date: date),
        scrollController: scrollController,
      ),
    );
  }
}

class _RankingModeBody extends ConsumerWidget {
  const _RankingModeBody({
    required this.feedKey,
    required this.scrollController,
  });

  final RankingFeedKey feedKey;
  final ScrollController scrollController;

  RankingMode get mode => feedKey.mode;

  /// Scroll restoration and hero tags per list: a past day is a different
  /// list from the latest one.
  String get _listId => switch (feedKey.date) {
    null => mode.name,
    final date => '${mode.name}-${formatApiDate(date)}',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(rankingFeedControllerProvider(feedKey));
    final store = ref.watch(illustStoreProvider);
    return state.when(
      loading: () => IllustGridSkeleton(label: context.l10n.contentLoading),
      error: (error, _) => FeedError(
        title: rankingLoadFailedTitle(context, mode),
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () => ref
            .read(rankingFeedControllerProvider(feedKey).notifier)
            .retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: rankingLoadFailedTitle(context, mode),
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.retry,
            onRetry: () => ref
                .read(rankingFeedControllerProvider(feedKey).notifier)
                .retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return IllustGridSkeleton(label: context.l10n.contentLoading);
        }
        if (feed.isEmptyAndReady) {
          return rankingEmpty(
            context,
            mode,
            () => ref
                .read(rankingFeedControllerProvider(feedKey).notifier)
                .refresh(),
          );
        }

        final entities = store.getAll(feed.ids);
        return PullToRefresh(
          scrollController: scrollController,
          onRefresh: () => ref
              .read(rankingFeedControllerProvider(feedKey).notifier)
              .refresh(),
          child: LoadMoreListener(
            itemCount: feed.ids.length,
            onLoadMore: () => ref
                .read(rankingFeedControllerProvider(feedKey).notifier)
                .loadMore(),
            child: SmoothWheelScroll(
              controller: scrollController,
              basePhysics: const AlwaysScrollableScrollPhysics(),
              builder: (context, controller, physics) =>
                  DeferredCacheScrollView(
                    key: PageStorageKey('ranking-$_listId'),
                    controller: controller,
                    physics: physics,
                    scrollCacheExtent: kFeedCacheExtent,
                    restorationId: 'ranking-$_listId',
                    slivers: [
                      IllustFeedGrid(
                        itemIds: [for (final e in entities) e.id],
                        itemCount: entities.length,
                        pagerLoadMore: () => ref
                            .read(
                              rankingFeedControllerProvider(feedKey).notifier,
                            )
                            .loadMore(),
                        warmTexts: (context, index) =>
                            IllustCard.warmTexts(context, entities[index]),
                        items: entities,
                        itemDeps: _listId,
                        itemBuilder: (context, index) => IllustCard(
                          entity: entities[index],
                          heroScope: 'ranking:$_listId',
                          rank: index + 1,
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: FeedTail(
                          feed: feed,
                          onRetry: () => ref
                              .read(
                                rankingFeedControllerProvider(feedKey).notifier,
                              )
                              .retryLoadMore(),
                          errorTitle: context.l10n.rankingLoadMoreFailed,
                          retryLabel: context.l10n.retry,
                        ),
                      ),
                      const SliverToBoxAdapter(child: FuncNavBarSpacer()),
                    ],
                  ),
            ),
          ),
        );
      },
    );
  }
}
