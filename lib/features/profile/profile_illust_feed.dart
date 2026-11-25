import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/layout/deferred_cache_scroll_view.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_selection.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../core/entity/illust_entity.dart';
import '../../core/entity/illust_store.dart';
import '../../core/network/api_error.dart';
import '../../core/profile/profile_feed_controller.dart';
import '../../core/profile/profile_models.dart';
import '../../l10n/context.dart';
import '../../app/widgets/feed/load_more_listener.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/icons/ui_icons.dart';
import 'profile_work_tag_filter.dart';

/// Grid padding shared by this feed and `ProfileSkeleton`'s grid block.
const gridPadding = IllustFeedGrid.defaultPadding;

/// Whether [feedKey] currently holds at least one loaded work to show
/// (including while refreshing or paging over existing items), excluding
/// initial loading, initial errors and empty feeds.
bool hasVisibleProfileIllusts(WidgetRef ref, ProfileFeedKey feedKey) {
  final feed = ref.watch(profileIllustFeedProvider(feedKey)).value;
  if (feed == null || feed.showInitialError || feed.ids.isEmpty) {
    return false;
  }
  final store = ref.watch(illustStoreProvider);
  return store.getAll(feed.ids).isNotEmpty;
}

class ProfileIllustFeed extends ConsumerWidget {
  const ProfileIllustFeed({
    super.key,
    required this.feedKey,
    this.localFilter,
    this.onClearLocalFilter,
    this.isNested = true,
  });

  final ProfileFeedKey feedKey;
  final String? localFilter;
  final VoidCallback? onClearLocalFilter;

  /// True inside [UserPage]'s `NestedScrollView`; false on standalone pages
  /// (bookmark tag feed, wide Me workspace panes) so pull-to-refresh omits
  /// `nestedHeader` and pointer wheels get `SmoothWheelScroll`.
  final bool isNested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(profileIllustFeedProvider(feedKey));
    return async.when(
      loading: () => IllustGridSkeleton(
        label: context.l10n.contentLoading,
        padding: gridPadding,
      ),
      error: (error, _) => FeedError(
        title: context.l10n.profileLoadFailed,
        error: error,
        retryLabel: context.l10n.profileRetry,
        onRetry: () => ref
            .read(profileIllustFeedProvider(feedKey).notifier)
            .retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: context.l10n.profileLoadFailed,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.profileRetry,
            onRetry: () => ref
                .read(profileIllustFeedProvider(feedKey).notifier)
                .retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return IllustGridSkeleton(
            label: context.l10n.contentLoading,
            padding: gridPadding,
          );
        }
        final controller = ref.read(
          profileIllustFeedProvider(feedKey).notifier,
        );
        final store = ref.watch(illustStoreProvider);
        final entities = store.getAll(feed.ids);
        final query = localFilter?.trim().toLowerCase() ?? '';
        final visibleEntities = query.isEmpty
            ? entities
            : entities
                  .where((entity) => _matchesLocalFilter(entity, query))
                  .toList(growable: false);
        final heroScope =
            'profile:${feedKey.userId}:${feedKey.kind.name}:'
            '${feedKey.workType.name}:${feedKey.restrict.name}:'
            '${feedKey.bookmarkTag ?? ''}';
        Widget buildScroll(
          ScrollController? scrollController,
          ScrollPhysics? physics,
        ) {
          return PullToRefresh(
            isNested: isNested,
            scrollController: scrollController,
            onRefresh: () =>
                ref.read(profileIllustFeedProvider(feedKey).notifier).refresh(),
            child: LoadMoreListener(
              itemCount: feed.ids.length,
              onLoadMore: () => ref
                  .read(profileIllustFeedProvider(feedKey).notifier)
                  .loadMore(),
              child: DeferredCacheScrollView(
                key: PageStorageKey(feedKey),
                controller: scrollController,
                restorationId: 'profile-${feedKey.toString()}',
                physics: physics,
                scrollCacheExtent: kFeedCacheExtent,
                slivers: [
                  if (isNested) PullToRefresh.nestedHeader,
                  if (visibleEntities.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      // Bookmarks are not filtered: an empty page there is
                      // not the filters' doing.
                      child:
                          feed.isAllHidden &&
                              query.isEmpty &&
                              controller.localFilterEnabled
                          ? FeedAllHidden(
                              feed: feed,
                              onLoadMore: controller.retryLoadMore,
                            )
                          : query.isNotEmpty
                          ? ProfileFilteredEmptyState(
                              hasMore: !feed.exhausted,
                              loadingMore: feed.showLoadMoreSpinner,
                              onLoadMore: () => controller.retryLoadMore(),
                              onClearFilter: onClearLocalFilter,
                            )
                          : FeedEmpty(
                              icon: UiIcons.inbox,
                              title: context.l10n.profileItemsEmpty,
                            ),
                    )
                  else
                    IllustFeedGrid(
                      padding: gridPadding,
                      itemIds: [for (final e in visibleEntities) e.id],
                      itemCount: visibleEntities.length,
                      pagerLoadMore: () => ref
                          .read(profileIllustFeedProvider(feedKey).notifier)
                          .loadMore(),
                      warmTexts: (context, index) =>
                          IllustCard.warmTexts(context, visibleEntities[index]),
                      items: visibleEntities,
                      itemDeps: heroScope,
                      itemBuilder: (context, index) => IllustCard(
                        entity: visibleEntities[index],
                        heroScope: heroScope,
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: FeedTail(
                      feed: feed,
                      onRetry: () => ref
                          .read(profileIllustFeedProvider(feedKey).notifier)
                          .retryLoadMore(),
                      errorTitle: context.l10n.profileLoadMoreFailed,
                      retryLabel: context.l10n.profileRetry,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        // Inside NestedScrollView, driving position via SmoothWheelScroll's
        // animateTo bypasses the nested coordinator so the profile header would
        // never collapse on wheel; standalone callers get SmoothWheelScroll.
        return ProfileFilterRefillRunner(
          filterKey: query.isEmpty ? null : '$feedKey:$query',
          visibleCount: visibleEntities.length,
          loadedCount: feed.ids.length,
          hasMore: !feed.exhausted,
          loadingMore: feed.showLoadMoreSpinner,
          hasLoadMoreError: feed.showLoadMoreError,
          onLoadMore: () => controller.loadMore(),
          child: SelectableFeedHost(
            child: isNested
                ? buildScroll(null, const AlwaysScrollableScrollPhysics())
                : SmoothWheelScroll(
                    basePhysics: const AlwaysScrollableScrollPhysics(),
                    builder: (context, scrollController, physics) =>
                        buildScroll(scrollController, physics),
                  ),
          ),
        );
      },
    );
  }
}

bool _matchesLocalFilter(IllustEntity entity, String query) =>
    entity.title.toLowerCase().contains(query) ||
    entity.tags.any(
      (tag) =>
          tag.name.toLowerCase().contains(query) ||
          (tag.translatedName?.toLowerCase().contains(query) ?? false),
    );
