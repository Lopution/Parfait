import 'package:flutter/material.dart';

import '../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_refresh/easy_refresh.dart';

import '../../app/icons/app_icons.dart';
import '../../app/widgets/novel_card.dart';
import '../../app/person_avatar.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/navigation/routes.dart';
import '../../core/auth/account_store.dart';
import '../../core/entity/illust_store.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_feed_controller.dart';
import '../../core/novel/novel_store.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import '../../core/user/user_store.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import 'follow_switch_button.dart';
import '../../core/profile/profile_feed_controller.dart';
import 'profile_header_delegate.dart';
import '../../core/profile/profile_models.dart';
import '../../core/user/user_detail_controller.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';

/// Remote user profile. [id] is accepted as a beta56-compatible alias for
/// callers migrating from the original UserPage.
class UserPage extends ConsumerStatefulWidget {
  const UserPage({super.key, int? id, int? userId, this.onEditProfile})
    : userId = userId ?? id ?? 0,
      isMe = false,
      assert(userId != null || id != null);

  const UserPage._me({required this.userId, this.onEditProfile}) : isMe = true;

  final int userId;
  final bool isMe;
  final VoidCallback? onEditProfile;

  @override
  ConsumerState<UserPage> createState() => _UserPageState();
}

/// Current-account profile. The account id is resolved at build time so an
/// account switch cannot leave a stale UserPage mounted for the old account.
class MePage extends ConsumerWidget {
  const MePage({super.key, this.onEditProfile});

  final VoidCallback? onEditProfile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountStoreProvider);
    return accounts.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => _ProfileStatusPage(
        icon: Icons.cloud_off,
        title: context.l10n.profileLoadFailed,
        detail: '$error',
        onRetry: () => ref.read(accountStoreProvider.notifier).reload(),
      ),
      data: (state) {
        if (state.status == AccountStatus.failure) {
          return _ProfileStatusPage(
            icon: Icons.cloud_off,
            title: context.l10n.accountReadFailed,
            detail: '${state.error ?? 'unknown account error'}',
            onRetry: () => ref.read(accountStoreProvider.notifier).reload(),
          );
        }
        final account = state.usableCurrent;
        if (account == null) {
          return _ProfileStatusPage(
            icon: Icons.person_off_outlined,
            title: context.l10n.signedOut,
            detail: context.l10n.noAccounts,
          );
        }
        return UserPage._me(
          userId: account.userId,
          onEditProfile: onEditProfile,
        );
      },
    );
  }
}

String _profileText(BuildContext context, String key) => l10nLookup(context.l10n, key);

class _UserPageState extends ConsumerState<UserPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final List<String> _tabKeys;
  bool _selectorExpanded = false;
  UserWorkType _workType = UserWorkType.illust;
  UserRestrict _restrict = UserRestrict.public;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabKeys = widget.isMe
        ? const [
            'profileBookmarked',
            'profileFollowing',
            'profileFans',
            'profileMyPixiv',
            'profileWork',
          ]
        : const [
            'profileWork',
            'profileBookmarked',
            'profileFollowing',
            'profileAbout',
          ];
    _tabController = TabController(length: _tabKeys.length, vsync: this)
      ..addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index == _selectedIndex ||
        _tabController.indexIsChanging) {
      return;
    }
    setState(() {
      _selectedIndex = _tabController.index;
      _selectorExpanded = false;
    });
  }

  void _onTabTap(int index) {
    final workTabIndex = widget.isMe ? _tabKeys.length - 1 : 0;
    if (index == _selectedIndex &&
        index == workTabIndex &&
        !_tabController.indexIsChanging) {
      setState(() => _selectorExpanded = !_selectorExpanded);
    }
  }

  ProfileFeedKey? _feedKeyFor(int index) {
    if (widget.isMe) {
      return switch (index) {
        0 => ProfileFeedKey(
          userId: widget.userId,
          kind: ProfileFeedKind.bookmarks,
          restrict: _restrict,
        ),
        1 => ProfileFeedKey(
          userId: widget.userId,
          kind: ProfileFeedKind.following,
          restrict: _restrict,
        ),
        2 => ProfileFeedKey(userId: widget.userId, kind: ProfileFeedKind.fans),
        3 => ProfileFeedKey(
          userId: widget.userId,
          kind: ProfileFeedKind.myPixiv,
        ),
        4 => ProfileFeedKey(
          userId: widget.userId,
          kind: ProfileFeedKind.work,
          workType: _workType,
        ),
        _ => null,
      };
    }
    return switch (index) {
      0 => ProfileFeedKey(
        userId: widget.userId,
        kind: ProfileFeedKind.work,
        workType: _workType,
      ),
      1 => ProfileFeedKey(
        userId: widget.userId,
        kind: ProfileFeedKind.bookmarks,
        restrict: _restrict,
      ),
      2 => ProfileFeedKey(
        userId: widget.userId,
        kind: ProfileFeedKind.following,
        restrict: _restrict,
      ),
      _ => null,
    };
  }

  void _onWorkTypeChanged(UserWorkType type) {
    setState(() {
      _workType = type;
      _selectorExpanded = false;
    });
  }

  void _onRestrictChanged(UserRestrict restrict) {
    setState(() => _restrict = restrict);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(userDetailControllerProvider(widget.userId));
    return Scaffold(
      body: async.when(
        loading: () => _ProfileStatusPage(
          icon: Icons.person_search_outlined,
          title: context.l10n.profileLoading,
        ),
        error: (error, _) => _ProfileStatusPage(
          icon: Icons.cloud_off,
          title: context.l10n.profileLoadFailed,
          detail: '$error',
          onRetry: () => ref
              .read(userDetailControllerProvider(widget.userId).notifier)
              .reload(),
        ),
        data: _buildLoaded,
      ),
    );
  }

  Widget _buildLoaded(UserDetailState state) {
    return switch (state) {
      UserDetailLoading() => _ProfileStatusPage(
        icon: Icons.person_search_outlined,
        title: context.l10n.profileLoading,
      ),
      UserDetailNotFound() => _ProfileStatusPage(
        icon: Icons.person_off_outlined,
        title: context.l10n.profileNotFound,
      ),
      UserDetailBlocked() => _ProfileStatusPage(
        icon: Icons.block_outlined,
        title: context.l10n.profileBlocked,
      ),
      UserDetailReady(:final user) => _buildProfile(user),
      UserDetailError(:final error, :final snapshot) when snapshot != null =>
        _buildProfile(snapshot, staleError: error),
      UserDetailError(:final error) => _ProfileStatusPage(
        icon: Icons.cloud_off,
        title: context.l10n.profileLoadFailed,
        detail: '$error',
        onRetry: () => ref
            .read(userDetailControllerProvider(widget.userId).notifier)
            .reload(),
      ),
    };
  }

  Widget _buildProfile(UserEntity user, {ApiError? staleError}) {
    final showRestrictSelector =
        widget.isMe && (_selectedIndex == 0 || _selectedIndex == 1);
    return Column(
      children: [
        if (staleError != null)
          MaterialBanner(
            content: Text(
              '${context.l10n.profileLoadFailed}: $staleError',
            ),
            actions: [
              TextButton(
                onPressed: () => ref
                    .read(userDetailControllerProvider(widget.userId).notifier)
                    .reload(),
                child: Text(context.l10n.profileRetry),
              ),
            ],
          ),
        Expanded(
          child: NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) => [
              SliverPersistentHeader(
                pinned: true,
                delegate: ReplicaProfileHeaderDelegate(
                  user: user,
                  isMe: widget.isMe,
                  selectedTabIndex: _selectedIndex,
                  showRestrictSelector: showRestrictSelector,
                  restrict: _restrict,
                  onRestrictChanged: _onRestrictChanged,
                  onShare: () => _showProfileShare(context, user),
                  onEditProfile: widget.isMe ? widget.onEditProfile : null,
                  topInset: MediaQuery.viewPaddingOf(context).top,
                ),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: ReplicaProfileTabsDelegate(
                  controller: _tabController,
                  isMe: widget.isMe,
                  expanded: _selectorExpanded,
                  workType: _workType,
                  onTabTap: _onTabTap,
                  onWorkTypeChanged: _onWorkTypeChanged,
                ),
              ),
            ],
            body: TabBarView(
              controller: _tabController,
              children: [
                for (var index = 0; index < _tabKeys.length; index++)
                  _ProfileTabBody(
                    key: ValueKey<Object?>(
                      _feedKeyFor(index) ?? _tabKeys[index],
                    ),
                    user: user,
                    userId: widget.userId,
                    isMe: widget.isMe,
                    tabIndex: index,
                    feedKey: _feedKeyFor(index),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileTabBody extends ConsumerStatefulWidget {
  const _ProfileTabBody({
    super.key,
    required this.user,
    required this.userId,
    required this.isMe,
    required this.tabIndex,
    required this.feedKey,
  });

  final UserEntity user;
  final int userId;
  final bool isMe;
  final int tabIndex;
  final ProfileFeedKey? feedKey;

  @override
  ConsumerState<_ProfileTabBody> createState() => _ProfileTabBodyState();
}

class _ProfileTabBodyState extends ConsumerState<_ProfileTabBody>
    with AutomaticKeepAliveClientMixin<_ProfileTabBody> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final feedKey = widget.feedKey;
    if (feedKey == null) return _ProfileAbout(user: widget.user);
    if (feedKey.workType == UserWorkType.novel) {
      // TabController.indexIsChanging is false during a drag gesture. Keep
      // the page mounted for both tap and swipe transitions so the destination
      // never becomes a zero-size blank child mid-flight.
      return _ProfileNovelFeed(userId: feedKey.userId);
    }
    if (feedKey.kind == ProfileFeedKind.following ||
        feedKey.kind == ProfileFeedKind.fans ||
        feedKey.kind == ProfileFeedKind.myPixiv) {
      return _ProfileUserFeed(feedKey: feedKey);
    }
    return _ProfileIllustFeed(feedKey: feedKey);
  }
}

class _ProfileIllustFeed extends ConsumerWidget {
  const _ProfileIllustFeed({required this.feedKey});

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
      )
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

class _ProfileUserFeed extends ConsumerWidget {
  const _ProfileUserFeed({required this.feedKey});

  final ProfileFeedKey feedKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(profileUserFeedProvider(feedKey));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
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
          return const Center(child: CircularProgressIndicator());
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
                  notification is ScrollEndNotification &&
                  notification.metrics.extentAfter < 400) {
                ref.read(profileUserFeedProvider(feedKey).notifier).loadMore();
              }
              return false;
            },
            child: ListView.builder(
              key: PageStorageKey(feedKey),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: (users.isEmpty ? 1 : users.length + 1) + 1,
              itemBuilder: (context, index) {
                if (index == 0) return const HeaderLocator();
                final itemIndex = index - 1;
                if (users.isEmpty) {
                  return FeedEmpty(
                    icon: Icons.inbox_outlined,
                    title: context.l10n.profileItemsEmpty,
                    onRefresh: () => ref
                        .read(profileUserFeedProvider(feedKey).notifier)
                        .refresh(),
                  );
                }
                if (itemIndex == users.length) {
                  return FeedTail(
        feed: feed,
        onRetry: () => ref
                        .read(profileUserFeedProvider(feedKey).notifier)
                        .retryLoadMore(),
        errorTitle: context.l10n.profileLoadMoreFailed,
        retryLabel: context.l10n.profileRetry,
      );
                }
                return _UserPreviewCard(user: users[itemIndex]);
              },
            ),
          ),
        );
      },
    );
  }
}

class _UserPreviewCard extends StatelessWidget {
  const _UserPreviewCard({required this.user});

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

class _ProfileAbout extends StatelessWidget {
  const _ProfileAbout({required this.user});

  final UserEntity user;

  @override
  Widget build(BuildContext context) {
    final entries = <({String label, String value})>[
      (label: context.l10n.profileId, value: '${user.id}'),
      if (user.account.isNotEmpty)
        (label: context.l10n.profileAccount, value: user.account),
      if (user.comment != null)
        (
          label: context.l10n.profileIntroduction,
          value: user.comment!,
        ),
      if (user.webpage != null)
        (label: context.l10n.profileWebsite, value: user.webpage!),
      if (user.twitterUrl != null) (label: 'Twitter', value: user.twitterUrl!),
      if (user.pawooUrl != null) (label: 'Pawoo', value: user.pawooUrl!),
    ];
    return ListView(
      key: const PageStorageKey('profile-about'),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
      children: [
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.label,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                SelectableText(entry.value),
              ],
            ),
          ),
        const Divider(),
        Text(
          context.l10n.profileStats,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        _ProfileStatRow(
          icon: AppIcons.follow,
          label: context.l10n.profileFollowing,
          value: user.totalFollowUsers,
        ),
        _ProfileStatRow(
          icon: AppIcons.friend,
          label: context.l10n.profileMyPixiv,
          value: user.totalMyPixivUsers,
        ),
        _ProfileStatRow(
          icon: Icons.palette_outlined,
          label: context.l10n.profileIllust,
          value: user.totalIllusts,
        ),
        _ProfileStatRow(
          icon: Icons.menu_book_outlined,
          label: context.l10n.profileManga,
          value: user.totalManga,
        ),
        _ProfileStatRow(
          icon: Icons.auto_stories_outlined,
          label: context.l10n.profileNovel,
          value: user.totalNovels,
        ),
      ],
    );
  }
}

class _ProfileNovelFeed extends ConsumerWidget {
  const _ProfileNovelFeed({required this.userId});

  final int userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userNovelFeedProvider(userId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
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
          return const Center(child: CircularProgressIndicator());
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

class _ProfileStatRow extends StatelessWidget {
  const _ProfileStatRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 18),
      title: Text(label),
      trailing: Text('$value'),
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


class _ProfileStatusPage extends StatelessWidget {
  const _ProfileStatusPage({
    required this.icon,
    required this.title,
    this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Navigator.of(context).canPop()
            ? IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_ios_new),
              )
            : null,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48),
              const SizedBox(height: 12),
              Text(title, textAlign: TextAlign.center),
              if (detail != null) ...[
                const SizedBox(height: 8),
                Text(detail!, textAlign: TextAlign.center),
              ],
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: onRetry,
                  child: Text(context.l10n.profileRetry),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

void _showProfileShare(BuildContext context, UserEntity user) {
  final url = 'https://www.pixiv.net/users/${user.id}';
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(_profileText(dialogContext, 'profileShare')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_profileText(dialogContext, 'profileShareHint')),
          const SizedBox(height: 10),
          SelectableText('$url\n${user.name}'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(_profileText(dialogContext, 'profileShareClose')),
        ),
      ],
    ),
  );
}
