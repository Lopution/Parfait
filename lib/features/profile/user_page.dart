import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/routes.dart';
import '../../app/icons/app_icons.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../app/widgets/follow_switch_button.dart';
import '../../core/auth/account_store.dart';
import '../../core/download/author_works_enumerator.dart';
import '../../core/network/api_error.dart';
import '../../core/platform/android_intent_channel.dart';
import '../../core/user/follow_actions.dart';
import '../../core/user/follow_store.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import 'author_works_download_dialog.dart';
import 'profile_illust_feed.dart';
import 'profile_novel_feed.dart';
import 'profile_user_feed.dart';
import 'profile_header_delegate.dart';
import 'user_series_feed.dart';
import '../../core/profile/profile_models.dart';
import '../../core/share/share_service.dart';
import '../../core/user/user_detail_controller.dart';
import '../../l10n/context.dart';

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
      loading: () => const Scaffold(body: FeedLoading()),
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
          onEditProfile:
              onEditProfile ?? () => openProfileEdit(context, account.userId),
        );
      },
    );
  }
}

enum _ProfileStatTarget { following, myPixiv, illust, manga, novel, series }

class _UserPageState extends ConsumerState<UserPage>
    with TickerProviderStateMixin {
  late final TabController _tabController;
  late final List<String> _tabKeys;
  late final ScrollController _outerScrollController;
  late final List<GlobalKey<_ProfileTabBodyState>> _bodyKeys;
  ProfileWorkSection _workSection = ProfileWorkSection.illust;
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
    _outerScrollController = ScrollController();
    _bodyKeys = [
      for (var index = 0; index < _tabKeys.length; index++)
        GlobalKey<_ProfileTabBodyState>(),
    ];
    _tabController = TabController(length: _tabKeys.length, vsync: this)
      ..addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    _outerScrollController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index == _selectedIndex ||
        _tabController.indexIsChanging) {
      return;
    }
    setState(() => _selectedIndex = _tabController.index);
  }

  void _onTabTap(int index) {
    if (index == _selectedIndex && !_tabController.indexIsChanging) {
      _scrollActiveTabToTop();
    }
  }

  void _scrollActiveTabToTop() {
    final animated = MotionTokens.enabled(context);
    final duration = MotionTokens.resolve(context, MotionTokens.fast);
    const curve = Curves.easeOutCubic;
    _bodyKeys[_selectedIndex].currentState?.scrollToTop(
      animated: animated,
      duration: duration,
      curve: curve,
    );
    // The outer controller's position is a _NestedScrollPosition too:
    // animateTo would broadcast through the nested coordinator and rewind
    // every keep-alive inner tab. Drive each attached position locally so
    // only the header expands.
    if (_outerScrollController.hasClients) {
      for (final position in _outerScrollController.positions) {
        _drivePositionToTop(
          this,
          position,
          animated: animated,
          duration: duration,
          curve: curve,
        );
      }
    }
  }

  /// Drives [position] to offset 0 through a local scroll activity. The
  /// profile feeds share the NestedScrollView's inner controller, whose
  /// positions route jumpTo/animateTo through the nested coordinator —
  /// and the coordinator broadcasts the motion to EVERY attached inner
  /// position, keep-alive sibling tabs included. A [DrivenScrollActivity]
  /// begun directly on the position touches only that offset.
  static void _drivePositionToTop(
    TickerProvider vsync,
    ScrollPosition position, {
    required bool animated,
    required Duration duration,
    required Curve curve,
  }) {
    // Every Scrollable position in this app is a
    // ScrollPositionWithSingleContext, which implements the delegate.
    final delegate = position is ScrollActivityDelegate
        ? position as ScrollActivityDelegate
        : null;
    if (delegate == null || !position.hasPixels) return;
    if (animated && duration > Duration.zero && position.pixels != 0) {
      position.beginActivity(
        DrivenScrollActivity(
          delegate,
          from: position.pixels,
          to: 0,
          duration: duration,
          curve: curve,
          vsync: vsync,
        ),
      );
      return;
    }
    // Local jumpTo(0): stop any in-flight activity, then write the offset
    // through the position's own setPixels — minus the coordinator
    // fan-out. setPixels still emits the scroll-position notification.
    position.beginActivity(IdleScrollActivity(delegate));
    position.setPixels(0);
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
          workType: _workSection.wireWorkType,
        ),
        _ => null,
      };
    }
    return switch (index) {
      0 => ProfileFeedKey(
        userId: widget.userId,
        kind: ProfileFeedKind.work,
        workType: _workSection.wireWorkType,
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

  void _onSectionChanged(ProfileWorkSection section) {
    if (section == _workSection) {
      _scrollActiveTabToTop();
      return;
    }
    setState(() => _workSection = section);
  }

  void _onRestrictChanged(UserRestrict restrict) {
    setState(() => _restrict = restrict);
  }

  List<ProfileStatisticData> _profileStatistics(UserEntity user) => [
    ProfileStatisticData(
      id: 'following',
      icon: AppIcons.follow,
      label: context.l10n.profileFollowing,
      value: user.totalFollowUsers,
      onTap: () => _navigateToStatistic(_ProfileStatTarget.following),
    ),
    ProfileStatisticData(
      id: 'myPixiv',
      icon: AppIcons.friend,
      label: context.l10n.profileMyPixiv,
      value: user.totalMyPixivUsers,
      onTap: widget.isMe
          ? () => _navigateToStatistic(_ProfileStatTarget.myPixiv)
          : null,
    ),
    ProfileStatisticData(
      id: 'illust',
      icon: Icons.palette_outlined,
      label: context.l10n.profileIllust,
      value: user.totalIllusts,
      onTap: () => _navigateToStatistic(_ProfileStatTarget.illust),
    ),
    ProfileStatisticData(
      id: 'manga',
      icon: Icons.menu_book_outlined,
      label: context.l10n.profileManga,
      value: user.totalManga,
      onTap: () => _navigateToStatistic(_ProfileStatTarget.manga),
    ),
    ProfileStatisticData(
      id: 'novel',
      icon: Icons.auto_stories_outlined,
      label: context.l10n.profileNovel,
      value: user.totalNovels,
      onTap: () => _navigateToStatistic(_ProfileStatTarget.novel),
    ),
    ProfileStatisticData(
      id: 'series',
      icon: Icons.collections_bookmark_outlined,
      label: context.l10n.profileSeries,
      // The series section hosts illust series only, so the count mirrors
      // what the destination lists (W3 D4: novel series stays unlisted).
      value: user.totalIllustSeries,
      onTap: () => _navigateToStatistic(_ProfileStatTarget.series),
    ),
  ];

  void _navigateToStatistic(_ProfileStatTarget target) {
    switch (target) {
      case _ProfileStatTarget.following:
        _navigateToTab('profileFollowing');
        break;
      case _ProfileStatTarget.myPixiv:
        _navigateToTab('profileMyPixiv');
        break;
      case _ProfileStatTarget.illust:
        _navigateToWorkSection(ProfileWorkSection.illust);
        break;
      case _ProfileStatTarget.manga:
        _navigateToWorkSection(ProfileWorkSection.manga);
        break;
      case _ProfileStatTarget.novel:
        _navigateToWorkSection(ProfileWorkSection.novel);
        break;
      case _ProfileStatTarget.series:
        _navigateToWorkSection(ProfileWorkSection.series);
        break;
    }
  }

  void _navigateToTab(String key) {
    final index = _tabKeys.indexOf(key);
    if (index < 0) return;
    if (index == _selectedIndex) {
      _scrollActiveTabToTop();
    } else {
      _tabController.animateTo(index);
    }
  }

  void _navigateToWorkSection(ProfileWorkSection section) {
    final workIndex = _tabKeys.indexOf('profileWork');
    if (workIndex < 0) return;
    final sameSection = _workSection == section;
    if (!sameSection) setState(() => _workSection = section);
    if (workIndex == _selectedIndex) {
      if (sameSection) _scrollActiveTabToTop();
    } else {
      _tabController.animateTo(workIndex);
    }
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

  Future<void> _downloadAuthorWorks() async {
    final submitted = await showAppDialog<int>(
      context: context,
      builder: (dialogContext) => AuthorWorksDownloadDialog(
        userId: widget.userId,
        enumerator: AuthorWorksEnumerator(ref.read(userRepositoryProvider)),
      ),
    );
    if (submitted != null && mounted) {
      showAppSnackBar(
        context,
        context.l10n.downloadQueuedMessage,
        action: SnackBarAction(
          label: context.l10n.downloadViewResult,
          onPressed: () => unawaited(openDownloadTasks(context)),
        ),
      );
    }
  }

  Widget _buildProfile(UserEntity user, {ApiError? staleError}) {
    final statistics = _profileStatistics(user);
    final followed = widget.isMe
        ? user.isFollowed ?? false
        : ref.watch(
                followStoreProvider.select((state) => state[user.id]?.followed),
              ) ??
              user.isFollowed ??
              false;
    final showRestrictSelector =
        widget.isMe && (_selectedIndex == 0 || _selectedIndex == 1);
    final workTabIndex = widget.isMe ? _tabKeys.length - 1 : 0;
    final canBulkDownload =
        _selectedIndex == workTabIndex &&
        (_workSection == ProfileWorkSection.illust ||
            _workSection == ProfileWorkSection.manga);
    return Column(
      children: [
        if (staleError != null)
          MaterialBanner(
            content: Text('${context.l10n.profileLoadFailed}: $staleError'),
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
            key: const ValueKey('profile-nested-scroll'),
            controller: _outerScrollController,
            headerSliverBuilder: (context, innerBoxIsScrolled) => [
              SliverPersistentHeader(
                pinned: true,
                delegate: ReplicaProfileHeaderDelegate(
                  user: user,
                  isMe: widget.isMe,
                  // The artwork band now stops well short of the old 430dp
                  // (it covered over half the screen). The /me header needs
                  // a little more room for the extra edit/settings row.
                  expandedExtent: widget.isMe ? 350 : 320,
                  selectedTabIndex: _selectedIndex,
                  showRestrictSelector: showRestrictSelector,
                  restrict: _restrict,
                  onRestrictChanged: _onRestrictChanged,
                  onShare: (originContext) =>
                      unawaited(_shareProfile(originContext, ref, user)),
                  isFollowed: followed,
                  onToggleFollow: widget.isMe
                      ? null
                      : () => ref.read(followActionsProvider).toggle(user.id),
                  onFollowPrivately: widget.isMe
                      ? null
                      : () => unawaited(
                          showFollowRestrictSheet(
                            context,
                            ref,
                            userId: user.id,
                            userName: user.name,
                            userAccount: user.account,
                          ),
                        ),
                  onCopyLink: () => unawaited(_copyProfileLink(context, user)),
                  statistics: statistics,
                  onEditProfile: widget.isMe ? widget.onEditProfile : null,
                  // Bookmarks tab only: the tag collection entry sits in the
                  // collapsed toolbar next to the restrict selector.
                  onOpenBookmarkTags: widget.isMe && _selectedIndex == 0
                      ? () => openBookmarkTags(context, restrict: _restrict)
                      : null,
                  onDownloadAll: canBulkDownload ? _downloadAuthorWorks : null,
                  topInset: MediaQuery.viewPaddingOf(context).top,
                ),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: ReplicaProfileTabsDelegate(
                  controller: _tabController,
                  isMe: widget.isMe,
                  section: _workSection,
                  onTabTap: _onTabTap,
                  onSectionChanged: _onSectionChanged,
                ),
              ),
            ],
            body: TabBarView(
              controller: _tabController,
              children: [
                for (var index = 0; index < _tabKeys.length; index++)
                  _ProfileTabBody(
                    key: _bodyKeys[index],
                    user: user,
                    userId: widget.userId,
                    isMe: widget.isMe,
                    tabIndex: index,
                    feedKey: _feedKeyFor(index),
                    workSection: _workSection,
                    statistics: statistics,
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
    required this.workSection,
    required this.statistics,
  });

  final UserEntity user;
  final int userId;
  final bool isMe;
  final int tabIndex;
  final ProfileFeedKey? feedKey;

  /// The work-tab selector value; only meaningful when [feedKey] is a
  /// `ProfileFeedKind.work` key (other tabs ignore it).
  final ProfileWorkSection workSection;
  final List<ProfileStatisticData> statistics;

  @override
  ConsumerState<_ProfileTabBody> createState() => _ProfileTabBodyState();
}

class _ProfileTabBodyState extends ConsumerState<_ProfileTabBody>
    with AutomaticKeepAliveClientMixin<_ProfileTabBody> {
  @override
  bool get wantKeepAlive => true;

  void scrollToTop({
    required bool animated,
    required Duration duration,
    required Curve curve,
  }) {
    // The feed's own Scrollable position is one of several attached to the
    // shared inner controller — driving it with a local activity rewinds
    // only this tab while sibling positions keep their offsets.
    final scrollable = _tabScrollable();
    final position = scrollable?.position;
    if (scrollable == null || position == null || !position.hasPixels) {
      return;
    }
    _UserPageState._drivePositionToTop(
      scrollable.vsync,
      position,
      animated: animated,
      duration: duration,
      curve: curve,
    );
  }

  /// The feed's own scroll view — the first Scrollable below this tab
  /// body.
  ScrollableState? _tabScrollable() {
    ScrollableState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        found = element.state as ScrollableState;
        return;
      }
      element.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    return found;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final feedKey = widget.feedKey;
    if (feedKey == null) {
      return _ProfileAbout(user: widget.user, statistics: widget.statistics);
    }
    if (feedKey.kind == ProfileFeedKind.work &&
        widget.workSection == ProfileWorkSection.series) {
      // The series section is a display selector over its own endpoint; the
      // wire workType fallback on feedKey is unused here.
      return UserSeriesFeed(userId: widget.userId);
    }
    if (feedKey.workType == UserWorkType.novel) {
      // TabController.indexIsChanging is false during a drag gesture. Keep
      // the page mounted for both tap and swipe transitions so the destination
      // never becomes a zero-size blank child mid-flight.
      return ProfileNovelFeed(userId: feedKey.userId);
    }
    if (feedKey.kind == ProfileFeedKind.following ||
        feedKey.kind == ProfileFeedKind.fans ||
        feedKey.kind == ProfileFeedKind.myPixiv) {
      return ProfileUserFeed(feedKey: feedKey);
    }
    return ProfileIllustFeed(feedKey: feedKey);
  }
}

class _ProfileAbout extends ConsumerWidget {
  const _ProfileAbout({required this.user, required this.statistics});

  final UserEntity user;
  final List<ProfileStatisticData> statistics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = <({String label, String value, String? socialId})>[
      (label: context.l10n.profileId, value: '${user.id}', socialId: null),
      if (user.account.isNotEmpty)
        (
          label: context.l10n.profileAccount,
          value: user.account,
          socialId: null,
        ),
      if (user.comment != null)
        (
          label: context.l10n.profileIntroduction,
          value: user.comment!,
          socialId: null,
        ),
      if (user.webpage != null)
        (
          label: context.l10n.profileWebsite,
          value: user.webpage!,
          socialId: 'website',
        ),
      if (user.twitterUrl != null)
        (label: 'Twitter', value: user.twitterUrl!, socialId: 'twitter'),
      if (user.pawooUrl != null)
        (label: 'Pawoo', value: user.pawooUrl!, socialId: 'pawoo'),
    ];
    return ListView(
      key: PageStorageKey('profile-about-${user.id}'),
      restorationId: 'profile-about-${user.id}',
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
      children: [
        for (final entry in entries)
          if (entry.socialId == null)
            _ProfileAboutTextEntry(label: entry.label, value: entry.value)
          else
            _ProfileSocialLinkRow(
              key: ValueKey('profile-link-${entry.socialId}'),
              id: entry.socialId!,
              label: entry.label,
              value: entry.value,
              onOpen: () =>
                  unawaited(_openProfileSocialLink(context, ref, entry.value)),
              onCopy: () =>
                  unawaited(_copyProfileSocialLink(context, entry.value)),
            ),
        const Divider(),
        Text(
          context.l10n.profileStats,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        for (final statistic in statistics)
          ProfileStatistic(statistic: statistic),
      ],
    );
  }
}

class _ProfileAboutTextEntry extends StatelessWidget {
  const _ProfileAboutTextEntry({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        SelectableText(value),
      ],
    ),
  );
}

class _ProfileSocialLinkRow extends StatelessWidget {
  const _ProfileSocialLinkRow({
    super.key,
    required this.id,
    required this.label,
    required this.value,
    required this.onOpen,
    required this.onCopy,
  });

  final String id;
  final String label;
  final String value;
  final VoidCallback onOpen;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: SelectableText(value)),
            IconButton(
              key: ValueKey('profile-link-open-$id'),
              tooltip: context.l10n.openLink,
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new),
            ),
            IconButton(
              key: ValueKey('profile-link-copy-$id'),
              tooltip: context.l10n.copyLink,
              onPressed: onCopy,
              icon: const Icon(Icons.copy_outlined),
            ),
          ],
        ),
      ],
    ),
  );
}

Future<void> _openProfileSocialLink(
  BuildContext context,
  WidgetRef ref,
  String url,
) async {
  try {
    await ref.read(outboundUrlOpenerProvider).openExternal(url);
  } on Object catch (error) {
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      context.l10n.illustDetailOpenLinkFailed(error.toString()),
    );
  }
}

Future<void> _copyProfileSocialLink(BuildContext context, String url) async {
  await Clipboard.setData(ClipboardData(text: url));
  if (!context.mounted) return;
  showAppSnackBar(context, context.l10n.linkCopied);
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
    return ReplicaScaffold(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: FeedEmpty(
            icon: icon,
            title: title,
            detail: detail,
            onRefresh: onRetry,
            retryLabel: context.l10n.profileRetry,
          ),
        ),
      ),
    );
  }
}

Future<void> _shareProfile(
  BuildContext originContext,
  WidgetRef ref,
  UserEntity user,
) async {
  final payload = SharePayload.user(id: user.id, name: user.name);
  final outcome = await ref
      .read(shareServiceProvider)
      .share(payload, sharePositionOrigin: shareOriginOf(originContext));
  if (outcome == ShareOutcome.copiedToClipboard && originContext.mounted) {
    showAppSnackBar(originContext, originContext.l10n.linkCopied);
  }
}

Future<void> _copyProfileLink(BuildContext context, UserEntity user) async {
  final payload = SharePayload.user(id: user.id, name: user.name);
  await Clipboard.setData(ClipboardData(text: payload.text));
  if (!context.mounted) return;
  showAppSnackBar(context, context.l10n.linkCopied);
}
