import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_refresh/easy_refresh.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../core/entity/illust_entity.dart';
import '../../core/entity/illust_store.dart';
import '../../core/network/api_error.dart';
import '../../core/profile/profile_feed_controller.dart';
import '../../core/profile/profile_models.dart';
import '../../l10n/context.dart';
import 'profile_work_type_switch.dart';

class ProfileIllustFeed extends ConsumerWidget {
  const ProfileIllustFeed({
    super.key,
    required this.feedKey,
    this.localFilter,
    this.typeSwitch,
  });

  final ProfileFeedKey feedKey;
  final String? localFilter;

  /// Work tab only: the compact section selector this feed hosts (D3). Null
  /// for feeds that are not the work tab (e.g. the bookmark-tag page).
  final ProfileWorkTypeSwitch? typeSwitch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(profileIllustFeedProvider(feedKey));
    final typeSwitch = this.typeSwitch;
    // Loading/error/empty states keep the switch as a fixed header so the
    // section stays switchable — same slot the floating version occupies
    // once data arrives.
    Widget wrapState(Widget state) =>
        typeSwitch?.aboveState(context, state) ?? state;
    return async.when(
      loading: () => wrapState(const FeedLoading()),
      error: (error, _) => wrapState(
        FeedError(
          title: context.l10n.profileLoadFailed,
          error: error,
          retryLabel: context.l10n.profileRetry,
          onRetry: () => ref
              .read(profileIllustFeedProvider(feedKey).notifier)
              .retryInitial(),
        ),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return wrapState(
            FeedError(
              title: context.l10n.profileLoadFailed,
              error: feed.initialError ?? const ApiParseError('unknown error'),
              retryLabel: context.l10n.profileRetry,
              onRetry: () => ref
                  .read(profileIllustFeedProvider(feedKey).notifier)
                  .retryInitial(),
            ),
          );
        }
        if (feed.showInitialSpinner) {
          return wrapState(const FeedLoading());
        }
        final store = ref.watch(illustStoreProvider);
        final entities = store.getAll(feed.ids);
        final query = localFilter?.trim().toLowerCase() ?? '';
        final visibleEntities = query.isEmpty
            ? entities
            : entities
                  .where((entity) => _matchesLocalFilter(entity, query))
                  .toList(growable: false);
        return PullToRefresh(
          isNested: true,
          onRefresh: () =>
              ref.read(profileIllustFeedProvider(feedKey).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.axis == Axis.vertical &&
                  notification is ScrollUpdateNotification &&
                  notification.metrics.extentAfter <
                      notification.metrics.viewportDimension * 1.2) {
                ref
                    .read(profileIllustFeedProvider(feedKey).notifier)
                    .loadMore();
              }
              return false;
            },
            // No SmoothWheelScroll here: this is the inner scrollable of a
            // NestedScrollView — driving its position via animateTo bypasses
            // the nested coordinator, so the profile header would never
            // collapse on wheel. Native wheel keeps header folding intact.
            child: CustomScrollView(
              key: PageStorageKey(feedKey),
              restorationId: 'profile-${feedKey.toString()}',
              physics: const AlwaysScrollableScrollPhysics(),
              scrollCacheExtent: kFeedCacheExtent,
              slivers: [
                const HeaderLocator.sliver(),
                if (typeSwitch != null) typeSwitch.sliver(context),
                if (visibleEntities.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: FeedEmpty(
                      icon: Icons.inbox_outlined,
                      title: query.isEmpty
                          ? context.l10n.profileItemsEmpty
                          : context.l10n.bookmarkTagFilterEmpty,
                      retryLabel: context.l10n.profileRetry,
                      onRefresh: () => ref
                          .read(profileIllustFeedProvider(feedKey).notifier)
                          .refresh(),
                    ),
                  )
                else
                  IllustFeedGrid(
                    padding: const EdgeInsets.all(10),
                    mainAxisSpacing: 5,
                    crossAxisSpacing: 10,
                    prefetchEntities: visibleEntities,
                    itemIds: [for (final e in visibleEntities) e.id],
                    itemCount: visibleEntities.length,
                    pagerLoadMore: () => ref
                        .read(profileIllustFeedProvider(feedKey).notifier)
                        .loadMore(),
                    itemBuilder: (context, index) => IllustCard(
                      entity: visibleEntities[index],
                      heroScope:
                          'profile:${feedKey.userId}:${feedKey.kind.name}:'
                          '${feedKey.workType.name}:${feedKey.restrict.name}:'
                          '${feedKey.bookmarkTag ?? ''}',
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
