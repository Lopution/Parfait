import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_refresh/easy_refresh.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/novel_card.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_feed_controller.dart';
import '../../core/novel/novel_store.dart';
import '../../l10n/context.dart';

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
                  notification is ScrollEndNotification &&
                  notification.metrics.extentAfter < 400) {
                ref.read(userNovelFeedProvider(userId).notifier).loadMore();
              }
              return false;
            },
            child: ListView.builder(
              key: PageStorageKey('profile-novel-$userId'),
              restorationId: 'profile-novel-$userId',
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: (novels.isEmpty ? 1 : novels.length + 1) + 1,
              itemBuilder: (context, index) {
                if (index == 0) return const HeaderLocator();
                final itemIndex = index - 1;
                if (novels.isEmpty) {
                  return FeedEmpty(
                    icon: Icons.inbox_outlined,
                    title: context.l10n.profileItemsEmpty,
                    onRefresh: () => ref
                        .read(userNovelFeedProvider(userId).notifier)
                        .refresh(),
                  );
                }
                if (itemIndex == novels.length) {
                  return FeedTail(
                    feed: feed,
                    onRetry: () => ref
                        .read(userNovelFeedProvider(userId).notifier)
                        .retryLoadMore(),
                    errorTitle: context.l10n.profileLoadMoreFailed,
                    retryLabel: context.l10n.profileRetry,
                  );
                }
                return NovelCard(entity: novels[itemIndex]);
              },
            ),
          ),
        );
      },
    );
  }
}
