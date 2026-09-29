import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_refresh/easy_refresh.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/novel_entry.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_feed_controller.dart';
import '../../core/novel/novel_store.dart';
import '../../l10n/context.dart';
import 'profile_work_type_switch.dart';

class ProfileNovelFeed extends ConsumerWidget {
  const ProfileNovelFeed({super.key, required this.userId, this.typeSwitch});

  final int userId;

  /// Work tab only: the compact section selector this feed hosts (D3).
  final ProfileWorkTypeSwitch? typeSwitch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userNovelFeedProvider(userId));
    final typeSwitch = this.typeSwitch;
    Widget wrapState(Widget state) =>
        typeSwitch?.aboveState(context, state) ?? state;
    return async.when(
      loading: () => wrapState(const FeedLoading()),
      error: (error, _) => wrapState(
        FeedError(
          title: context.l10n.profileLoadFailed,
          error: error,
          retryLabel: context.l10n.profileRetry,
          onRetry: () =>
              ref.read(userNovelFeedProvider(userId).notifier).retryInitial(),
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
                  .read(userNovelFeedProvider(userId).notifier)
                  .retryInitial(),
            ),
          );
        }
        if (feed.showInitialSpinner) {
          return wrapState(const FeedLoading());
        }
        final storedNovels = ref.watch(novelStoreProvider);
        final novels = [
          for (final id in feed.ids)
            if (storedNovels[id] != null) storedNovels[id]!,
        ];
        return PullToRefresh(
          isNested: true,
          onRefresh: () =>
              ref.read(userNovelFeedProvider(userId).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.axis == Axis.vertical &&
                  notification is ScrollUpdateNotification &&
                  notification.metrics.extentAfter <
                      notification.metrics.viewportDimension * 1.2) {
                ref.read(userNovelFeedProvider(userId).notifier).loadMore();
              }
              return false;
            },
            child: CustomScrollView(
              key: PageStorageKey('profile-novel-$userId'),
              restorationId: 'profile-novel-$userId',
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                const HeaderLocator.sliver(),
                if (typeSwitch != null) typeSwitch.sliver(context),
                if (novels.isEmpty)
                  // Same centred empty state as the works tab — not a
                  // top-aligned list item.
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: FeedEmpty(
                      icon: Icons.inbox_outlined,
                      title: context.l10n.profileItemsEmpty,
                      retryLabel: context.l10n.profileRetry,
                      onRefresh: () => ref
                          .read(userNovelFeedProvider(userId).notifier)
                          .refresh(),
                    ),
                  )
                else
                  SliverList.builder(
                    itemCount: novels.length + 1,
                    itemBuilder: (context, index) {
                      if (index == novels.length) {
                        return FeedTail(
                          feed: feed,
                          onRetry: () => ref
                              .read(userNovelFeedProvider(userId).notifier)
                              .retryLoadMore(),
                          errorTitle: context.l10n.profileLoadMoreFailed,
                          retryLabel: context.l10n.profileRetry,
                        );
                      }
                      return NovelEntry.regular(entity: novels[index]);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
