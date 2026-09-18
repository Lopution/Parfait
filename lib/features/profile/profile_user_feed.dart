import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_refresh/easy_refresh.dart';

import '../../app/navigation/routes.dart';
import '../../app/person_avatar.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../core/network/api_error.dart';
import '../../core/profile/profile_feed_controller.dart';
import '../../core/profile/profile_models.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_store.dart';
import '../../l10n/context.dart';
import '../../app/widgets/follow_switch_button.dart';

class ProfileUserFeed extends ConsumerWidget {
  const ProfileUserFeed({super.key, required this.feedKey});

  final ProfileFeedKey feedKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(profileUserFeedProvider(feedKey));
    return async.when(
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: context.l10n.profileLoadFailed,
        error: error,
        retryLabel: context.l10n.profileRetry,
        onRetry: () =>
            ref.read(profileUserFeedProvider(feedKey).notifier).retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: context.l10n.profileLoadFailed,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.profileRetry,
            onRetry: () => ref
                .read(profileUserFeedProvider(feedKey).notifier)
                .retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return const FeedLoading();
        }
        final storedUsers = ref.watch(userStoreProvider);
        final users = [
          for (final id in feed.ids)
            if (storedUsers[id] != null) storedUsers[id]!,
        ];
        return PullToRefresh(
          isNested: true,
          onRefresh: () =>
              ref.read(profileUserFeedProvider(feedKey).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.axis == Axis.vertical &&
                  notification is ScrollUpdateNotification &&
                  notification.metrics.extentAfter <
                      notification.metrics.viewportDimension * 1.2) {
                ref.read(profileUserFeedProvider(feedKey).notifier).loadMore();
              }
              return false;
            },
            child: CustomScrollView(
              key: PageStorageKey(feedKey),
              restorationId: 'profile-${feedKey.toString()}',
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                const HeaderLocator.sliver(),
                if (users.isEmpty)
                  // Match the works tab: the empty state centres in the
                  // remaining viewport instead of sitting as a small block
                  // at the top of the scroll area.
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: FeedEmpty(
                      icon: Icons.inbox_outlined,
                      title: context.l10n.profileItemsEmpty,
                      retryLabel: context.l10n.profileRetry,
                      onRefresh: () => ref
                          .read(profileUserFeedProvider(feedKey).notifier)
                          .refresh(),
                    ),
                  )
                else
                  SliverList.builder(
                    itemCount: users.length + 1,
                    itemBuilder: (context, index) {
                      if (index == users.length) {
                        return FeedTail(
                          feed: feed,
                          onRetry: () => ref
                              .read(profileUserFeedProvider(feedKey).notifier)
                              .retryLoadMore(),
                          errorTitle: context.l10n.profileLoadMoreFailed,
                          retryLabel: context.l10n.profileRetry,
                        );
                      }
                      return _UserPreviewTile(user: users[index]);
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

class _UserPreviewTile extends StatelessWidget {
  const _UserPreviewTile({required this.user});

  final UserEntity user;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        onTap: () => openUser(context, user.id),
        leading: _ProfileAvatar(user: user, radius: 26),
        title: Text(user.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: user.account.isEmpty ? null : Text('@${user.account}'),
        trailing: FollowSwitchButton(
          userId: user.id,
          userName: user.name,
          userAccount: user.account,
          compact: true,
        ),
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.user, required this.radius});

  final UserEntity user;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return PersonAvatar(
      imageUrl: user.profileImageUrl,
      radius: radius,
      ring: true,
    );
  }
}
