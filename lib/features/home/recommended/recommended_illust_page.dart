import 'package:material_ui/material_ui.dart';

import '../../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/feed/feed_states.dart';
import '../../../app/widgets/feed/illust_card.dart';
import '../../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../../app/pull_to_refresh.dart';
import '../../../core/entity/illust_store.dart';

import '../../../core/illust/recommended_illust_controller.dart';
import '../../../l10n/context.dart';
import '../../../app/widgets/smooth_wheel_scroll.dart';
import '../../../app/theme/func_semantic_tokens.dart';

/// Grid padding shared by the feed sliver and its first-load skeleton:
/// horizontal margins plus the status-bar inset (this tab has no AppBar).
EdgeInsets _feedPadding(BuildContext context) => EdgeInsets.fromLTRB(
  FuncSpacing.sm,
  MediaQuery.viewPaddingOf(context).top,
  FuncSpacing.sm,
  0,
);

/// Recommended Illust tab: real API feed with initial/refresh/load-more
/// states, card badges matching beta56 IllustPreviewer, and retained state
/// across Home tab switches (IndexedStack keeps this element alive).
class RecommendedIllustPage extends ConsumerWidget {
  const RecommendedIllustPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(recommendedIllustControllerProvider);
    final store = ref.watch(illustStoreProvider);

    return state.when(
      loading: () => Scaffold(
        body: IllustGridSkeleton(
          label: context.l10n.contentLoading,
          padding: _feedPadding(context),
        ),
      ),
      error: (error, _) => Scaffold(
        body: FeedError(
          title: context.l10n.recommendedLoadFailed,
          error: error,
          retryLabel: context.l10n.retry,
          onRetry: () => ref
              .read(recommendedIllustControllerProvider.notifier)
              .retryInitial(),
        ),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return Scaffold(
            body: FeedError(
              title: context.l10n.recommendedLoadFailed,
              error: feed.initialError,
              retryLabel: context.l10n.retry,
              onRetry: () => ref
                  .read(recommendedIllustControllerProvider.notifier)
                  .retryInitial(),
            ),
          );
        }
        if (feed.showInitialSpinner) {
          return Scaffold(
            body: IllustGridSkeleton(
              label: context.l10n.contentLoading,
              padding: _feedPadding(context),
            ),
          );
        }
        if (feed.isEmptyAndReady) {
          return Scaffold(
            body: FeedEmpty(
              title: context.l10n.recommendedEmpty,
              retryLabel: context.l10n.refresh,
              onRefresh: () => ref
                  .read(recommendedIllustControllerProvider.notifier)
                  .refresh(),
            ),
          );
        }
        final entities = store.getAll(feed.ids);
        return Scaffold(
          body: PullToRefresh(
            onRefresh: () => ref
                .read(recommendedIllustControllerProvider.notifier)
                .refresh(),
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollUpdateNotification &&
                    notification.metrics.extentAfter <
                        notification.metrics.viewportDimension * 1.2) {
                  ref
                      .read(recommendedIllustControllerProvider.notifier)
                      .loadMore();
                }
                return false;
              },
              child: SmoothWheelScroll(
                builder: (context, controller, physics) => CustomScrollView(
                  key: const PageStorageKey('recommended-illust'),
                  // U1 (R7): this tab is the only one without an AppBar, so
                  // on edge-to-edge Android 15+ the top padding is otherwise
                  // zero and the feed overlaps the status bar. Only the top
                  // safe inset is added — no AppBar — so the immersive feed
                  // look is kept. The refresh indicator's overscroll zone
                  // stays above the padding, so pull-to-refresh still
                  // triggers.
                  restorationId: 'recommended-illust',
                  controller: controller,
                  physics: physics,
                  scrollCacheExtent: kFeedCacheExtent,
                  slivers: [
                    IllustFeedGrid(
                      padding: _feedPadding(context),
                      itemIds: [for (final e in entities) e.id],
                      itemCount: entities.length,
                      pagerLoadMore: () => ref
                          .read(recommendedIllustControllerProvider.notifier)
                          .loadMore(),
                      itemBuilder: (context, index) => IllustCard(
                        entity: entities[index],
                        heroScope: 'recommended:illust',
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: FeedTail(
                        feed: feed,
                        onRetry: () => ref
                            .read(recommendedIllustControllerProvider.notifier)
                            .retryLoadMore(),
                        errorTitle: context.l10n.recommendedLoadMoreFailed,
                        retryLabel: context.l10n.retry,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
