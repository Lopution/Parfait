import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/novel_entry.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_feed_controller.dart';
import '../../core/entity/stored_entities.dart';
import '../../core/novel/novel_store.dart';
import '../../l10n/context.dart';
import '../../app/layout/card_columns.dart';
import '../../app/widgets/feed/load_more_listener.dart';

class ProfileNovelFeed extends ConsumerWidget {
  const ProfileNovelFeed({super.key, required this.userId});

  final int userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userNovelFeedProvider(userId));
    return async.when(
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: context.l10n.profileLoadFailed,
        error: error,
        retryLabel: context.l10n.profileRetry,
        onRetry: () =>
            ref.read(userNovelFeedProvider(userId).notifier).retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: context.l10n.profileLoadFailed,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.profileRetry,
            onRetry: () =>
                ref.read(userNovelFeedProvider(userId).notifier).retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return const FeedLoading();
        }
        final novels = ref
            .watch(
              novelStoreProvider.select(
                (store) => StoredEntities(store, feed.ids),
              ),
            )
            .items;
        return PullToRefresh(
          isNested: true,
          onRefresh: () =>
              ref.read(userNovelFeedProvider(userId).notifier).refresh(),
          child: LoadMoreListener(
            itemCount: feed.ids.length,
            onLoadMore: () =>
                ref.read(userNovelFeedProvider(userId).notifier).loadMore(),
            child: CustomScrollView(
              key: PageStorageKey('profile-novel-$userId'),
              restorationId: 'profile-novel-$userId',
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                PullToRefresh.nestedHeader,
                if (novels.isEmpty)
                  // Same centred empty state as the works tab — not a
                  // top-aligned list item.
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: feed.isAllHidden
                        ? FeedAllHidden(
                            feed: feed,
                            onLoadMore: () => ref
                                .read(userNovelFeedProvider(userId).notifier)
                                .retryLoadMore(),
                          )
                        : FeedEmpty(
                            icon: Icons.inbox_outlined,
                            title: context.l10n.profileItemsEmpty,
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
                      onRetry: () => ref
                          .read(userNovelFeedProvider(userId).notifier)
                          .retryLoadMore(),
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
