import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_refresh/easy_refresh.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../core/entity/illust_store.dart';
import '../../core/network/api_error.dart';
import '../../core/profile/profile_feed_controller.dart';
import '../../core/profile/profile_models.dart';
import '../../l10n/context.dart';

class ProfileIllustFeed extends ConsumerWidget {
  const ProfileIllustFeed({super.key, required this.feedKey});

  final ProfileFeedKey feedKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(profileIllustFeedProvider(feedKey));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
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
          return const Center(child: CircularProgressIndicator());
        }
        final store = ref.watch(illustStoreProvider);
        final entities = store.getAll(feed.ids);
        return PullToRefresh(
          isNested: true,
          onRefresh: () =>
              ref.read(profileIllustFeedProvider(feedKey).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.axis == Axis.vertical &&
                  notification is ScrollEndNotification &&
                  notification.metrics.extentAfter < 400) {
                ref
                    .read(profileIllustFeedProvider(feedKey).notifier)
                    .loadMore();
              }
              return false;
            },
            child: CustomScrollView(
              key: PageStorageKey(feedKey),
              restorationId: 'profile-${feedKey.toString()}',
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                const HeaderLocator.sliver(),
                if (entities.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: FeedEmpty(
                      icon: Icons.inbox_outlined,
                      title: context.l10n.profileItemsEmpty,
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
                    itemCount: entities.length,
                    itemBuilder: (context, index) => IllustCard(
                      entity: entities[index],
                      heroScope:
                          'profile:${feedKey.userId}:${feedKey.kind.name}:'
                          '${feedKey.workType.name}:${feedKey.restrict.name}',
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
