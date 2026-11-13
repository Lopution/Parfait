import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/motion/reveal.dart';
import '../../app/motion/state_fade.dart';
import '../../app/format/app_format.dart';
import '../../app/navigation/routes.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/icons/app_icons.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../app/widgets/follow_switch_button.dart';
import '../../core/auth/account_store.dart';
import '../../core/download/author_works_enumerator.dart';
import '../../core/network/api_error.dart';
import '../../app/widgets/unmute_undo.dart';
import '../../core/mute/mute_models.dart';
import '../../core/mute/mute_store.dart';
import '../../core/user/follow_store.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import 'author_works_download_dialog.dart';
import 'profile_filter_bar.dart';
import 'profile_illust_feed.dart';
import 'profile_novel_feed.dart';
import 'profile_skeleton.dart';
import 'profile_user_feed.dart';
import 'profile_header_delegate.dart';
import 'profile_statistics.dart';
import 'user_series_feed.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/profile/profile_models.dart';
import '../../core/share/share_service.dart';
import '../../core/user/user_detail_controller.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/clipboard.dart';

import 'profile_about_tab.dart';

part 'profile_tab_body.dart';

/// Remote user profile. [id] is accepted as a beta56-compatible alias for
/// callers migrating from the original UserPage.
class UserPage extends ConsumerStatefulWidget {
  const UserPage({super.key, int? id, int? userId, this.onEditProfile})
    : userId = userId ?? id ?? 0,
      isMe = false,
      initialTab = null,
      assert(userId != null || id != null);

  const UserPage._me({
    required this.userId,
    this.onEditProfile,
    this.initialTab,
  }) : isMe = true;

  final int userId;
  final bool isMe;
  final VoidCallback? onEditProfile;

  /// Own profile only: the tab to open on instead of the first.
  final MeTab? initialTab;

  @override
  ConsumerState<UserPage> createState() => _UserPageState();
}

/// Current-account profile. The account id is resolved at build time so an
/// account switch cannot leave a stale UserPage mounted for the old account.
class MePage extends ConsumerWidget {
  const MePage({super.key, this.onEditProfile, this.initialTab});

  final VoidCallback? onEditProfile;

  /// The tab to open on; null opens the first (bookmarks).
  final MeTab? initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountStoreProvider);
    return accounts.when(
      loading: () => const Scaffold(body: FeedLoading()),
      error: (error, _) => _ProfileStatusPage(
        icon: Icons.cloud_off,
        title: context.l10n.profileLoadFailed,
        error: error,
        onRetry: () => ref.read(accountStoreProvider.notifier).reload(),
      ),
      data: (state) {
        if (state.status == AccountStatus.failure) {
          return _ProfileStatusPage(
            icon: Icons.cloud_off,
            title: context.l10n.accountReadFailed,
            error: state.error ?? StateError('account state unavailable'),
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
          initialTab: initialTab,
          onEditProfile:
              onEditProfile ?? () => openProfileEdit(context, account.userId),
        );
      },
    );
  }
}

/// One profile tab. The work tabs come first on another user's page and
/// last on your own; each appears only when the user has works of its type.
enum _ProfileTab {
  illust(ProfileWorkSection.illust),
  manga(ProfileWorkSection.manga),
  novel(ProfileWorkSection.novel),
  series(ProfileWorkSection.series),
  bookmarks(null),
  following(null),
  fans(null),
  myPixiv(null),
  about(null);

  const _ProfileTab(this.section);

  final ProfileWorkSection? section;
}

class _UserPageState extends ConsumerState<UserPage>
    with TickerProviderStateMixin {
  late final ScrollController _outerScrollController;

  /// Built with the first loaded profile and rebuilt whenever the visible
  /// tabs change (a refresh that adds or drops a work type).
  TabController? _tabController;
  List<_ProfileTab> _tabs = const [];
  final _bodyKeys = <_ProfileTab, GlobalKey<_ProfileTabBodyState>>{};
  UserRestrict _restrict = UserRestrict.public;

  /// The bookmarks tab's kind: illustrations or novels.
  BookmarkEntityType _bookmarkKind = BookmarkEntityType.illust;

  /// Own bookmarks only: the tag filter, null for every bookmark. Tags are
  /// per kind and visibility, so a change of either clears it.
  String? _bookmarkTag;
  int _selectedIndex = 0;
  bool _staleBannerVisible = true;

  /// Measured expanded height of the profile header (R1). Null until the
  /// identity block reports its first layout; the delegate renders one
  /// transparent estimate frame before that.
  double? _headerExtent;

  @override
  void initState() {
    super.initState();
    _outerScrollController = ScrollController();
  }

  @override
  void dispose() {
    _tabController
      ?..removeListener(_onTabChanged)
      ..dispose();
    _outerScrollController.dispose();
    super.dispose();
  }

  _ProfileTab? get _selectedTab => _tabs.isEmpty ? null : _tabs[_selectedIndex];

  /// Work types with something to show. Without the detail counters (a
  /// preview snapshot after a failed load) every type stays reachable.
  List<_ProfileTab> _tabsFor(UserEntity user) {
    final works = [
      if (!user.hasDetail || user.totalIllusts > 0) _ProfileTab.illust,
      if (!user.hasDetail || user.totalManga > 0) _ProfileTab.manga,
      if (!user.hasDetail || user.totalNovels > 0) _ProfileTab.novel,
      // The series tab lists illust series only (no endpoint lists a
      // user's novel series), so only they count.
      if (!user.hasDetail || user.totalIllustSeries > 0) _ProfileTab.series,
    ];
    return widget.isMe
        ? [
            _ProfileTab.bookmarks,
            _ProfileTab.following,
            _ProfileTab.fans,
            _ProfileTab.myPixiv,
            ...works,
          ]
        : [
            ...works,
            _ProfileTab.bookmarks,
            _ProfileTab.following,
            _ProfileTab.about,
          ];
  }

  /// Keeps the tab controller in step with [tabs]. The selected tab stays
  /// selected when it survives the change; otherwise the first tab is.
  TabController _syncTabs(List<_ProfileTab> tabs) {
    final current = _tabController;
    if (current != null && listEquals(tabs, _tabs)) return current;
    final kept =
        _selectedTab ??
        switch (widget.initialTab) {
          MeTab.bookmarks => _ProfileTab.bookmarks,
          MeTab.following => _ProfileTab.following,
          null => null,
        };
    final index = kept == null ? 0 : math.max(0, tabs.indexOf(kept));
    if (current != null) {
      current.removeListener(_onTabChanged);
      // The tab bar still listens until this frame swaps controllers.
      WidgetsBinding.instance.addPostFrameCallback((_) => current.dispose());
    }
    _tabs = tabs;
    _selectedIndex = index;
    return _tabController = TabController(
      length: tabs.length,
      initialIndex: index,
      vsync: this,
    )..addListener(_onTabChanged);
  }

  void _onTabChanged() {
    final controller = _tabController!;
    if (controller.index == _selectedIndex || controller.indexIsChanging) {
      return;
    }
    setState(() => _selectedIndex = controller.index);
  }

  void _onTabTap(int index) {
    if (index == _selectedIndex && !_tabController!.indexIsChanging) {
      _scrollActiveTabToTop();
    }
  }

  /// Names only: a count would widen the labels past an equal share of
  /// the row, and the row would switch to scrolling once the counts load.
  /// Work totals sit above their lists instead ([_worksTotalFor]).
  String _tabLabel(_ProfileTab tab) {
    final l10n = context.l10n;
    return switch (tab) {
      _ProfileTab.illust => l10n.profileIllust,
      _ProfileTab.manga => l10n.profileManga,
      _ProfileTab.novel => l10n.profileNovel,
      _ProfileTab.series => l10n.profileSeries,
      _ProfileTab.bookmarks => l10n.profileBookmarked,
      _ProfileTab.following => l10n.profileFollowing,
      _ProfileTab.fans => l10n.profileFans,
      _ProfileTab.myPixiv => l10n.profileMyPixiv,
      _ProfileTab.about => l10n.profileAbout,
    };
  }

  void _scrollActiveTabToTop() {
    Duration resolve(Duration base) => MotionTokens.resolve(context, base);
    final tab = _selectedTab;
    if (tab == null) return;
    _bodyKeys[tab]?.currentState?.scrollToTop(resolve);
    // The outer controller's position is a _NestedScrollPosition too:
    // animateTo would broadcast through the nested coordinator and rewind
    // every keep-alive inner tab. Drive each attached position locally so
    // only the header expands.
    if (_outerScrollController.hasClients) {
      for (final position in _outerScrollController.positions) {
        _drivePositionToTop(this, position, resolve);
      }
    }
  }

  /// Drives [position] to offset 0 through a local scroll activity. The
  /// selected feed sits on the NestedScrollView's inner controller, whose
  /// positions route jumpTo/animateTo through the nested coordinator, and
  /// the coordinator moves the header along. A [DrivenScrollActivity]
  /// begun directly on the position touches only that offset. [resolve]
  /// turns the base duration into the played one ([MotionTokens.resolve]).
  static void _drivePositionToTop(
    TickerProvider vsync,
    ScrollPosition position,
    Duration Function(Duration base) resolve,
  ) {
    // Every Scrollable position in this app is a
    // ScrollPositionWithSingleContext, which implements the delegate.
    final delegate = position is ScrollActivityDelegate
        ? position as ScrollActivityDelegate
        : null;
    if (delegate == null || !position.hasPixels) return;
    final plan = MotionTokens.scrollToTop(
      position.pixels,
      position.viewportDimension,
    );
    final duration = resolve(plan.duration);
    // A local jumpTo: stop any in-flight activity, then write the offset
    // through the position's own setPixels — minus the coordinator
    // fan-out. setPixels still emits the scroll-position notification.
    void jump(double to) {
      position.beginActivity(IdleScrollActivity(delegate));
      position.setPixels(to);
    }

    if (duration == Duration.zero || position.pixels == 0) {
      jump(0);
      return;
    }
    if (plan.start < position.pixels) jump(plan.start);
    position.beginActivity(
      DrivenScrollActivity(
        delegate,
        from: position.pixels,
        to: 0,
        duration: duration,
        curve: MotionTokens.spatialCurve,
        vsync: vsync,
      ),
    );
  }

  ProfileFeedKey? _feedKeyFor(_ProfileTab tab) {
    final userId = widget.userId;
    return switch (tab) {
      _ProfileTab.illust ||
      _ProfileTab.manga ||
      _ProfileTab.novel ||
      _ProfileTab.series => ProfileFeedKey(
        userId: userId,
        kind: ProfileFeedKind.work,
        workType: tab.section!.wireWorkType,
      ),
      _ProfileTab.bookmarks => ProfileFeedKey(
        userId: userId,
        kind: ProfileFeedKind.bookmarks,
        workType: _bookmarkKind == BookmarkEntityType.novel
            ? UserWorkType.novel
            : UserWorkType.illust,
        restrict: _restrict,
        bookmarkTag: _bookmarkTag,
      ),
      _ProfileTab.following => ProfileFeedKey(
        userId: userId,
        kind: ProfileFeedKind.following,
        restrict: _restrict,
      ),
      _ProfileTab.fans => ProfileFeedKey(
        userId: userId,
        kind: ProfileFeedKind.fans,
      ),
      _ProfileTab.myPixiv => ProfileFeedKey(
        userId: userId,
        kind: ProfileFeedKind.myPixiv,
      ),
      _ProfileTab.about => null,
    };
  }

  void _onRestrictChanged(UserRestrict restrict) {
    setState(() {
      _restrict = restrict;
      _bookmarkTag = null;
    });
  }

  void _onBookmarkKindChanged(BookmarkEntityType kind) {
    setState(() {
      _bookmarkKind = kind;
      _bookmarkTag = null;
    });
  }

  /// The filters above the bookmarks and follows lists: on someone else's
  /// bookmarks (public ones only) the kind alone.
  Widget? _filterBarFor(_ProfileTab tab) {
    if (!widget.isMe) {
      return tab == _ProfileTab.bookmarks
          ? ProfileFilterBar(
              kind: _bookmarkKind,
              onKindChanged: _onBookmarkKindChanged,
            )
          : null;
    }
    return switch (tab) {
      _ProfileTab.bookmarks => ProfileFilterBar(
        kind: _bookmarkKind,
        onKindChanged: _onBookmarkKindChanged,
        restrict: _restrict,
        onRestrictChanged: _onRestrictChanged,
        tag: _bookmarkTag,
        onTagChanged: (tag) => setState(() => _bookmarkTag = tag),
      ),
      _ProfileTab.following => ProfileFilterBar(
        restrict: _restrict,
        onRestrictChanged: _onRestrictChanged,
      ),
      _ => null,
    };
  }

  /// A work tab's total, above its list. A preview snapshot has no
  /// counters, so it shows none rather than zero.
  Widget? _worksTotalFor(_ProfileTab tab, UserEntity user) {
    if (!user.hasDetail) return null;
    final count = switch (tab) {
      _ProfileTab.illust => user.totalIllusts,
      _ProfileTab.manga => user.totalManga,
      _ProfileTab.novel => user.totalNovels,
      _ProfileTab.series => user.totalIllustSeries,
      _ => null,
    };
    return count == null ? null : _WorksTotal(count: count);
  }

  /// Opens [tab] — or, when it is already open, scrolls it to the top. Null
  /// when the profile has no such tab.
  VoidCallback? _openTab(_ProfileTab tab) {
    if (!_tabs.contains(tab)) return null;
    return () {
      final index = _tabs.indexOf(tab);
      if (index == _selectedIndex) {
        _scrollActiveTabToTop();
      } else {
        _tabController!.animateTo(index);
      }
    };
  }

  /// The header's counters. A preview snapshot has no counters, so it
  /// shows none rather than zeros.
  List<ProfileHeaderStat> _headerStats(UserEntity user) {
    if (!user.hasDetail) return const [];
    final l10n = context.l10n;
    return [
      ProfileHeaderStat(
        id: 'following',
        value: user.totalFollowUsers,
        label: l10n.profileFollowing,
        onTap: _openTab(_ProfileTab.following),
      ),
      ProfileHeaderStat(
        id: 'myPixiv',
        value: user.totalMyPixivUsers,
        label: l10n.profileMyPixiv,
        onTap: _openTab(_ProfileTab.myPixiv),
      ),
    ];
  }

  List<ProfileStatisticData> _profileStatistics(UserEntity user) => [
    ProfileStatisticData(
      id: 'following',
      icon: AppIcons.follow,
      label: context.l10n.profileFollowing,
      value: user.totalFollowUsers,
      onTap: _openTab(_ProfileTab.following),
    ),
    ProfileStatisticData(
      id: 'myPixiv',
      icon: AppIcons.friend,
      label: context.l10n.profileMyPixiv,
      value: user.totalMyPixivUsers,
      onTap: _openTab(_ProfileTab.myPixiv),
    ),
    ProfileStatisticData(
      id: 'illust',
      icon: Icons.palette_outlined,
      label: context.l10n.profileIllust,
      value: user.totalIllusts,
      onTap: _openTab(_ProfileTab.illust),
    ),
    ProfileStatisticData(
      id: 'manga',
      icon: Icons.menu_book_outlined,
      label: context.l10n.profileManga,
      value: user.totalManga,
      onTap: _openTab(_ProfileTab.manga),
    ),
    ProfileStatisticData(
      id: 'novel',
      icon: Icons.auto_stories_outlined,
      label: context.l10n.profileNovel,
      value: user.totalNovels,
      onTap: _openTab(_ProfileTab.novel),
    ),
    ProfileStatisticData(
      id: 'series',
      icon: Icons.collections_bookmark_outlined,
      label: context.l10n.profileSeries,
      // The series tab hosts illust series only, so the count mirrors what
      // the destination lists (W3 D4: novel series stays unlisted).
      value: user.totalIllustSeries,
      onTap: _openTab(_ProfileTab.series),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(userDetailControllerProvider(widget.userId));
    final body = async.when(
      loading: () => const ProfileSkeleton(),
      error: (error, _) => _ProfileStatusPage(
        icon: Icons.cloud_off,
        title: context.l10n.profileLoadFailed,
        error: error,
        onRetry: () => ref
            .read(userDetailControllerProvider(widget.userId).notifier)
            .reload(),
      ),
      data: _buildLoaded,
    );
    // The skeleton hands over to the profile with a fade; status pages are
    // FeedEmpty, which fades in by itself.
    return Scaffold(
      body: StateFade(kind: body is ProfileSkeleton, child: body),
    );
  }

  Widget _buildLoaded(UserDetailState state) {
    return switch (state) {
      UserDetailLoading() => const ProfileSkeleton(),
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
        error: error,
        onRetry: () => ref
            .read(userDetailControllerProvider(widget.userId).notifier)
            .reload(),
      ),
    };
  }

  Future<void> _reloadProfile() async {
    if (mounted && !_staleBannerVisible) {
      setState(() => _staleBannerVisible = true);
    }
    await ref
        .read(userDetailControllerProvider(widget.userId).notifier)
        .reload();
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
      showDownloadSubmittedSnackBar(context, alreadyQueued: submitted == 0);
    }
  }

  Widget _buildProfile(UserEntity user, {ApiError? staleError}) {
    final tabController = _syncTabs(_tabsFor(user));
    final selectedTab = _selectedTab;
    final statistics = _profileStatistics(user);
    final followed = widget.isMe
        ? user.isFollowed ?? false
        : ref.watch(
                followStoreProvider.select((state) => state[user.id]?.shown),
              ) ??
              user.isFollowed ??
              false;
    final canBulkDownload =
        selectedTab == _ProfileTab.illust || selectedTab == _ProfileTab.manga;
    final muted = ref.watch(
      muteStoreProvider.select((state) => state.isUserMuted(user.id)),
    );
    return Column(
      children: [
        Reveal(
          child: staleError == null || !_staleBannerVisible
              ? null
              : MaterialBanner(
                  content: Text(context.l10n.profileLoadFailed),
                  actions: [
                    TextButton(
                      key: const ValueKey('profile-stale-error-retry'),
                      onPressed: _reloadProfile,
                      child: Text(context.l10n.profileRetry),
                    ),
                    IconButton(
                      key: const ValueKey('profile-stale-error-dismiss'),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: () =>
                          setState(() => _staleBannerVisible = false),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
        ),
        Expanded(
          child: NestedScrollView(
            key: const ValueKey('profile-nested-scroll'),
            controller: _outerScrollController,
            // The outer position must share the inner feeds' physics family:
            // the coordinator runs one ballistic simulation per position over
            // the combined metrics, and the feeds fling with the app's
            // FuncScrollPhysics (PullToRefresh keeps it under EasyRefresh's
            // nested physics). The widget default would pin the outer to
            // Clamping, whose simulation diverges from it at low release
            // speeds — the header then stops short while the feed is
            // already rolling ("dip"), and a light pull-down dies on the
            // edge ("stuck"). On top, the outer scroll holds while a feed's
            // refresh header is pulled out, so a reversed pull retracts it.
            physics: NestedRefreshOuterPhysics(
              parent: ScrollConfiguration.of(context).getScrollPhysics(context),
            ),
            headerSliverBuilder: (context, innerBoxIsScrolled) => [
              SliverPersistentHeader(
                pinned: true,
                delegate: ReplicaProfileHeaderDelegate(
                  user: user,
                  isMe: widget.isMe,
                  // The expanded height is measured from the real identity
                  // content (R1): the delegate reports it after every
                  // layout, so font scale, language and stat-count changes
                  // all land without any hard-coded extent.
                  expandedExtent: _headerExtent,
                  onExpandedExtentMeasured: (extent) {
                    if (!mounted) return;
                    if (_headerExtent == null ||
                        (extent - _headerExtent!).abs() > 0.5) {
                      setState(() => _headerExtent = extent);
                    }
                  },
                  selectedTabIndex: _selectedIndex,
                  onShare: (originContext) =>
                      unawaited(_shareProfile(originContext, ref, user)),
                  isFollowed: followed,
                  onToggleFollow: widget.isMe
                      ? null
                      : () => toggleFollowWithUndo(context, user.id),
                  onFollowPrivately: widget.isMe
                      ? null
                      : () => unawaited(
                          showFollowActionsSheet(
                            context,
                            userId: user.id,
                            userName: user.name,
                            userAccount: user.account,
                          ),
                        ),
                  onCopyLink: () => unawaited(_copyProfileLink(context, user)),
                  stats: _headerStats(user),
                  onEditProfile: widget.isMe ? widget.onEditProfile : null,
                  onDownloadAll: canBulkDownload ? _downloadAuthorWorks : null,
                  isMuted: muted,
                  onToggleMute: widget.isMe
                      ? null
                      : () => unawaited(
                          toggleUserMute(
                            context,
                            MutedUser(
                              userId: user.id,
                              name: user.name,
                              account: user.account,
                              profileImageUrl: user.profileImageUrl,
                            ),
                          ),
                        ),
                  topInset: MediaQuery.viewPaddingOf(context).top,
                ),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: ReplicaProfileTabsDelegate(
                  controller: tabController,
                  labels: [for (final tab in _tabs) _tabLabel(tab)],
                  onTabTap: _onTabTap,
                  scrolled: innerBoxIsScrolled,
                ),
              ),
            ],
            body: TabBarView(
              controller: tabController,
              children: [
                for (final (index, tab) in _tabs.indexed)
                  _SelectedTabScroll(
                    selected: index == _selectedIndex,
                    child: _ProfileTabBody(
                      key: _bodyKeys.putIfAbsent(tab, GlobalKey.new),
                      user: user,
                      userId: widget.userId,
                      isSeries: tab == _ProfileTab.series,
                      feedKey: _feedKeyFor(tab),
                      header: _filterBarFor(tab) ?? _worksTotalFor(tab, user),
                      statistics: statistics,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileStatusPage extends StatelessWidget {
  const _ProfileStatusPage({
    required this.icon,
    required this.title,
    this.detail,
    this.error,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Object? error;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return ReplicaScaffold(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.xl),
          child: FeedEmpty(
            icon: icon,
            title: title,
            detail: detail,
            error: error,
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
  await copyToClipboard(
    context,
    payload.text,
    message: context.l10n.linkCopied,
  );
}
