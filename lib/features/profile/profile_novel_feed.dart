import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/novel_entry.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_feed_controller.dart';
import '../../core/paging/paged_feed_controller.dart';
import '../../core/profile/profile_models.dart';
import '../../core/entity/stored_entities.dart';
import '../../core/novel/novel_store.dart';
import '../../l10n/context.dart';
import '../../app/layout/card_columns.dart';
import '../../app/widgets/feed/load_more_listener.dart';

/// A user's novels, or their novel bookmarks when [feedKey] is a
/// bookmarks key. [localFilter] narrows the loaded list to titles and tags
/// that contain it, as on the illust list.
class ProfileNovelFeed extends ConsumerWidget {
  const ProfileNovelFeed({super.key, required this.feedKey, this.localFilter});

  final ProfileFeedKey feedKey;
  final String? localFilter;

  bool get _bookmarks => feedKey.kind == ProfileFeedKind.bookmarks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    PagedFeedController controller() => _bookmarks
        ? ref.read(userNovelBookmarksFeedProvider(feedKey).notifier)
        : ref.read(userNovelFeedProvider(feedKey.userId).notifier);
    final async = ref.watch(
      _bookmarks
          ? userNovelBookmarksFeedProvider(feedKey)
          : userNovelFeedProvider(feedKey.userId),
    );
    return async.when(
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: context.l10n.profileLoadFailed,
        error: error,
        retryLabel: context.l10n.profileRetry,
        onRetry: () => controller().retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: context.l10n.profileLoadFailed,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.profileRetry,
            onRetry: () => controller().retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return const FeedLoading();
        }
        final loaded = ref
            .watch(
              novelStoreProvider.select(
                (store) => StoredEntities(store, feed.ids),
              ),
            )
            .items;
        final query = localFilter?.trim().toLowerCase() ?? '';
        final novels = query.isEmpty
            ? loaded
            : [
                for (final novel in loaded)
                  if (_matchesLocalFilter(novel, query)) novel,
              ];
        // The works list keeps its storage id; the bookmarks list takes
        // its key's, like the illust lists.
        final storageId = _bookmarks
            ? 'profile-$feedKey'
            : 'profile-novel-${feedKey.userId}';
        return PullToRefresh(
          isNested: true,
          onRefresh: () => controller().refresh(),
          child: LoadMoreListener(
            itemCount: feed.ids.length,
            onLoadMore: () => controller().loadMore(),
            child: CustomScrollView(
              key: PageStorageKey(storageId),
              restorationId: storageId,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                PullToRefresh.nestedHeader,
                if (novels.isEmpty)
                  // Same centred empty state as the works tab — not a
                  // top-aligned list item.
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: feed.isAllHidden && query.isEmpty
                        ? FeedAllHidden(
                            feed: feed,
                            onLoadMore: () => controller().retryLoadMore(),
                          )
                        : FeedEmpty(
                            icon: Icons.inbox_outlined,
                            title: query.isEmpty
                                ? context.l10n.profileItemsEmpty
                                : context.l10n.bookmarkTagFilterEmpty,
                          ),
                  )
                else ...[
                  SliverCardList(
                    itemCount: novels.length,
                    firstId: novels.first.id,
                    warmTexts: (context, index) =>
                        NovelEntry.warmTexts(context, novels[index]),
                    items: novels,
                    itemBuilder: (context, index) =>
                        NovelEntry.regular(entity: novels[index]),
                  ),
                  SliverToBoxAdapter(
                    child: FeedTail(
                      feed: feed,
                      onRetry: () => controller().retryLoadMore(),
                      errorTitle: context.l10n.profileLoadMoreFailed,
                      retryLabel: context.l10n.profileRetry,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

bool _matchesLocalFilter(NovelEntity novel, String query) =>
    novel.title.toLowerCase().contains(query) ||
    novel.tags.any(
      (tag) =>
          tag.name.toLowerCase().contains(query) ||
          (tag.translatedName?.toLowerCase().contains(query) ?? false),
    );
