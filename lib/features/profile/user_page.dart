import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../app/icons/app_icons.dart';
import '../../app/pixiv_image.dart';
import '../../app/replica_page_route.dart';
import '../../core/auth/account_store.dart';
import '../../core/entity/illust_store.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_feed_controller.dart';
import '../../core/novel/novel_store.dart';
import '../../core/paging/paged_feed_controller.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import '../../core/user/user_store.dart';
import '../home/recommended/recommended_illust_page.dart';
import '../novel/novel_page.dart';
import '../settings/settings_page.dart';
import 'follow_switch_button.dart';
import 'profile_feed_controller.dart';
import 'profile_header_delegate.dart';
import 'profile_models.dart';
import 'user_detail_controller.dart';

/// Remote user profile. [id] is accepted as a beta56-compatible alias for
/// callers migrating from the original UserPage.
class UserPage extends ConsumerStatefulWidget {
  const UserPage({super.key, int? id, int? userId, this.onSettings})
    : userId = userId ?? id ?? 0,
      isMe = false,
      assert(userId != null || id != null);

  const UserPage._me({required this.userId, this.onSettings}) : isMe = true;

  final int userId;
  final bool isMe;
  final VoidCallback? onSettings;

  @override
  ConsumerState<UserPage> createState() => _UserPageState();
}

/// Current-account profile. The account id is resolved at build time so an
/// account switch cannot leave a stale UserPage mounted for the old account.
class MePage extends ConsumerWidget {
  const MePage({super.key, this.onSettings});

  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountStoreProvider);
    return accounts.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => _ProfileStatusPage(
        icon: Icons.cloud_off,
        title: _profileText(context, 'profileLoadFailed'),
        detail: '$error',
        onRetry: () => ref.read(accountStoreProvider.notifier).reload(),
      ),
      data: (state) {
        final account = state.usableCurrent;
        if (account == null) {
          return _ProfileStatusPage(
            icon: Icons.person_off_outlined,
            title: _profileText(context, 'signedOut'),
            detail: _profileText(context, 'noAccounts'),
          );
        }
        return UserPage._me(userId: account.userId, onSettings: onSettings);
      },
    );
  }
}

/// Opens a typed user route using the same right-in navigation rhythm as
/// detail/ranking pages.
void showUserPage(BuildContext context, int userId) {
  if (userId <= 0) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(_profileText(context, 'profileNotFound'))),
    );
    return;
  }
  Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(builder: (_) => UserPage(userId: userId)),
  );
}

void showMePage(BuildContext context, {VoidCallback? onSettings}) {
  Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(builder: (_) => MePage(onSettings: onSettings)),
  );
}

String _profileText(BuildContext context, String key) => ReplicaStrings.fromTag(
  Localizations.localeOf(context).toLanguageTag(),
  key,
);

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
    if (index == _selectedIndex && !_tabController.indexIsChanging) {
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
          title: _profileText(context, 'profileLoading'),
        ),
        error: (error, _) => _ProfileStatusPage(
          icon: Icons.cloud_off,
          title: _profileText(context, 'profileLoadFailed'),
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
        title: _profileText(context, 'profileLoading'),
      ),
      UserDetailNotFound() => _ProfileStatusPage(
        icon: Icons.person_off_outlined,
        title: _profileText(context, 'profileNotFound'),
      ),
      UserDetailBlocked() => _ProfileStatusPage(
        icon: Icons.block_outlined,
        title: _profileText(context, 'profileBlocked'),
      ),
      UserDetailReady(:final user) => _buildProfile(user),
      UserDetailError(:final error, :final snapshot) when snapshot != null =>
        _buildProfile(snapshot, staleError: error),
      UserDetailError(:final error) => _ProfileStatusPage(
        icon: Icons.cloud_off,
        title: _profileText(context, 'profileLoadFailed'),
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
              '${_profileText(context, 'profileLoadFailed')}: $staleError',
            ),
            actions: [
              TextButton(
                onPressed: () => ref
                    .read(userDetailControllerProvider(widget.userId).notifier)
                    .reload(),
                child: Text(_profileText(context, 'profileRetry')),
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
                  onSettings: widget.isMe
                      ? (widget.onSettings ??
                            () => Navigator.of(context).push<void>(
                              ReplicaPageRoute<void>(
                                builder: (_) => const SettingsPage(),
                              ),
                            ))
                      : null,
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
                    active: index == _selectedIndex,
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
    required this.active,
  });

  final UserEntity user;
  final int userId;
  final bool isMe;
  final int tabIndex;
  final ProfileFeedKey? feedKey;
  final bool active;

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
      return widget.active
          ? _ProfileNovelFeed(userId: feedKey.userId)
          : const SizedBox.shrink();
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
      error: (error, _) => _ProfileFeedError(
        error: error,
        onRetry: () => ref
            .read(profileIllustFeedProvider(feedKey).notifier)
            .retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return _ProfileFeedError(
            error: feed.initialError ?? const ApiParseError('unknown error'),
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
        return RefreshIndicator(
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
                if (entities.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(_profileText(context, 'profileItemsEmpty')),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.all(10),
                    sliver: SliverMasonryGrid.count(
                      crossAxisCount: 2,
                      mainAxisSpacing: 5,
                      crossAxisSpacing: 10,
                      itemBuilder: (context, index) =>
                          IllustCard(entity: entities[index]),
                      childCount: entities.length,
                    ),
                  ),
                SliverToBoxAdapter(
                  child: _ProfileFeedTail(
                    feed: feed,
                    onRetry: () => ref
                        .read(profileIllustFeedProvider(feedKey).notifier)
                        .retryLoadMore(),
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
      error: (error, _) => _ProfileFeedError(
        error: error,
        onRetry: () =>
            ref.read(profileUserFeedProvider(feedKey).notifier).retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return _ProfileFeedError(
            error: feed.initialError ?? const ApiParseError('unknown error'),
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
        return RefreshIndicator(
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
              itemCount: users.isEmpty ? 1 : users.length + 1,
              itemBuilder: (context, index) {
                if (users.isEmpty) {
                  return SizedBox(
                    height: 240,
                    child: Center(
                      child: Text(_profileText(context, 'profileItemsEmpty')),
                    ),
                  );
                }
                if (index == users.length) {
                  return _ProfileFeedTail(
                    feed: feed,
                    onRetry: () => ref
                        .read(profileUserFeedProvider(feedKey).notifier)
                        .retryLoadMore(),
                  );
                }
                return _UserPreviewCard(user: users[index]);
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
        onTap: () => showUserPage(context, user.id),
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
      (label: _profileText(context, 'profileId'), value: '${user.id}'),
      if (user.account.isNotEmpty)
        (label: _profileText(context, 'profileAccount'), value: user.account),
      if (user.comment != null)
        (
          label: _profileText(context, 'profileIntroduction'),
          value: user.comment!,
        ),
      if (user.webpage != null)
        (label: _profileText(context, 'profileWebsite'), value: user.webpage!),
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
          _profileText(context, 'profileStats'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        _ProfileStatRow(
          icon: AppIcons.follow,
          label: _profileText(context, 'profileFollowing'),
          value: user.totalFollowUsers,
        ),
        _ProfileStatRow(
          icon: AppIcons.friend,
          label: _profileText(context, 'profileMyPixiv'),
          value: user.totalMyPixivUsers,
        ),
        _ProfileStatRow(
          icon: Icons.palette_outlined,
          label: _profileText(context, 'profileIllust'),
          value: user.totalIllusts,
        ),
        _ProfileStatRow(
          icon: Icons.menu_book_outlined,
          label: _profileText(context, 'profileManga'),
          value: user.totalManga,
        ),
        _ProfileStatRow(
          icon: Icons.auto_stories_outlined,
          label: _profileText(context, 'profileNovel'),
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
      error: (error, _) => _ProfileFeedError(
        error: error,
        onRetry: () =>
            ref.read(userNovelFeedProvider(userId).notifier).retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return _ProfileFeedError(
            error: feed.initialError ?? const ApiParseError('unknown error'),
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
        return RefreshIndicator(
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
              itemCount: novels.isEmpty ? 1 : novels.length + 1,
              itemBuilder: (context, index) {
                if (novels.isEmpty) {
                  return SizedBox(
                    height: 240,
                    child: Center(
                      child: Text(_profileText(context, 'profileItemsEmpty')),
                    ),
                  );
                }
                if (index == novels.length) {
                  return _ProfileFeedTail(
                    feed: feed,
                    onRetry: () => ref
                        .read(userNovelFeedProvider(userId).notifier)
                        .retryLoadMore(),
                  );
                }
                return NovelCard(entity: novels[index]);
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
    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: user.profileImageUrl == null
          ? Icon(Icons.person_outline, size: radius)
          : ClipOval(
              child: SizedBox(
                width: radius * 2,
                height: radius * 2,
                child: PixivImage(
                  url: user.profileImageUrl!,
                  fit: BoxFit.cover,
                ),
              ),
            ),
    );
  }
}

class _ProfileFeedTail extends StatelessWidget {
  const _ProfileFeedTail({required this.feed, required this.onRetry});

  final PagedFeedState feed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (feed.showLoadMoreSpinner) {
      return const Padding(
        padding: EdgeInsets.all(18),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (feed.showLoadMoreError) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_profileText(context, 'profileLoadMoreFailed')),
            TextButton(
              onPressed: onRetry,
              child: Text(_profileText(context, 'profileRetry')),
            ),
          ],
        ),
      );
    }
    return const SizedBox(height: 24);
  }
}

class _ProfileFeedError extends StatelessWidget {
  const _ProfileFeedError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 42),
            const SizedBox(height: 8),
            Text(_profileText(context, 'profileLoadFailed')),
            const SizedBox(height: 6),
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: onRetry,
              child: Text(_profileText(context, 'profileRetry')),
            ),
          ],
        ),
      ),
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
                tooltip: 'Back',
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
                  child: Text(_profileText(context, 'profileRetry')),
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
