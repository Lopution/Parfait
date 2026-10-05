import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/motion/state_fade.dart';
import '../../app/format/app_format.dart';
import '../../app/navigation/routes.dart';
import '../../app/icons/app_icons.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/errors/error_details.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../app/widgets/follow_switch_button.dart';
import '../../core/auth/account_store.dart';
import '../../core/download/author_works_enumerator.dart';
import '../../core/network/api_error.dart';
import '../../core/platform/android_intent_channel.dart';
import '../../core/user/follow_store.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import 'author_works_download_dialog.dart';
import 'profile_illust_feed.dart';
import 'profile_novel_feed.dart';
import 'profile_skeleton.dart';
import 'profile_user_feed.dart';
import 'profile_header_delegate.dart';
import 'profile_statistics.dart';
import 'user_series_feed.dart';
import '../../core/profile/profile_models.dart';
import '../../core/share/share_service.dart';
import '../../core/user/user_detail_controller.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/clipboard.dart';

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
    final kept = _selectedTab;
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

  String _tabLabel(_ProfileTab tab, UserEntity user) {
    final l10n = context.l10n;
    String work(String name, int count) =>
        user.hasDetail ? '$name ${AppFormat.count(context, count)}' : name;
    return switch (tab) {
      _ProfileTab.illust => work(l10n.profileIllust, user.totalIllusts),
      _ProfileTab.manga => work(l10n.profileManga, user.totalManga),
      _ProfileTab.novel => work(l10n.profileNovel, user.totalNovels),
      _ProfileTab.series => work(l10n.profileSeries, user.totalIllustSeries),
      _ProfileTab.bookmarks => l10n.profileBookmarked,
      _ProfileTab.following => l10n.profileFollowing,
      _ProfileTab.fans => l10n.profileFans,
      _ProfileTab.myPixiv => l10n.profileMyPixiv,
      _ProfileTab.about => l10n.profileAbout,
    };
  }

  void _scrollActiveTabToTop() {
    final animated = MotionTokens.enabled(context);
    final duration = MotionTokens.resolve(context, MotionTokens.fast);
    const curve = Curves.easeOutCubic;
    final tab = _selectedTab;
    if (tab == null) return;
    _bodyKeys[tab]?.currentState?.scrollToTop(
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
        restrict: _restrict,
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
    setState(() => _restrict = restrict);
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
                followStoreProvider.select((state) => state[user.id]?.followed),
              ) ??
              user.isFollowed ??
              false;
    final showRestrictSelector =
        widget.isMe &&
        (selectedTab == _ProfileTab.bookmarks ||
            selectedTab == _ProfileTab.following);
    final canBulkDownload =
        selectedTab == _ProfileTab.illust || selectedTab == _ProfileTab.manga;
    return Column(
      children: [
        if (staleError != null && _staleBannerVisible)
          MaterialBanner(
            content: Text(context.l10n.profileLoadFailed),
            actions: [
              TextButton(
                key: const ValueKey('profile-stale-error-retry'),
                onPressed: _reloadProfile,
                child: Text(context.l10n.profileRetry),
              ),
              IconButton(
                key: const ValueKey('profile-stale-error-dismiss'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => setState(() => _staleBannerVisible = false),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        Expanded(
          child: NestedScrollView(
            key: const ValueKey('profile-nested-scroll'),
            controller: _outerScrollController,
            // The outer position must share the inner feeds' physics family:
            // the coordinator runs one ballistic simulation per position over
            // the combined metrics, and the feeds' EasyRefresh physics always
            // builds a BouncingScrollSimulation. The widget default would pin
            // the outer to Clamping, whose simulation diverges from it at low
            // release speeds — the header then stops short while the feed is
            // already rolling ("dip"), and a light pull-down dies on the edge
            // ("stuck").
            physics: ScrollConfiguration.of(context).getScrollPhysics(context),
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
                  showRestrictSelector: showRestrictSelector,
                  restrict: _restrict,
                  onRestrictChanged: _onRestrictChanged,
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
                  onOpenBookmarkTags:
                      widget.isMe && selectedTab == _ProfileTab.bookmarks
                      ? () => openBookmarkTags(context, restrict: _restrict)
                      : null,
                  onDownloadAll: canBulkDownload ? _downloadAuthorWorks : null,
                  topInset: MediaQuery.viewPaddingOf(context).top,
                ),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: ReplicaProfileTabsDelegate(
                  controller: tabController,
                  labels: [for (final tab in _tabs) _tabLabel(tab, user)],
                  onTabTap: _onTabTap,
                ),
              ),
            ],
            body: TabBarView(
              controller: tabController,
              children: [
                for (final tab in _tabs)
                  _ProfileTabBody(
                    key: _bodyKeys.putIfAbsent(tab, GlobalKey.new),
                    user: user,
                    userId: widget.userId,
                    isSeries: tab == _ProfileTab.series,
                    feedKey: _feedKeyFor(tab),
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
    required this.isSeries,
    required this.feedKey,
    required this.statistics,
  });

  final UserEntity user;
  final int userId;

  /// The series tab lists series from its own endpoint; its [feedKey]'s
  /// wire work type is unused.
  final bool isSeries;
  final ProfileFeedKey? feedKey;
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
    if (widget.isSeries) return UserSeriesFeed(userId: widget.userId);
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
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.xl,
        FuncSpacing.md,
        FuncSpacing.xl,
        FuncSpacing.xxl,
      ),
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
        const SizedBox(height: FuncSpacing.sm),
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
    padding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: FuncSpacing.xs),
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
    padding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: FuncSpacing.xs),
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
    showErrorSnackBar(
      context,
      action: context.l10n.illustDetailOpenLinkFailed,
      error: error,
    );
  }
}

Future<void> _copyProfileSocialLink(BuildContext context, String url) =>
    copyToClipboard(context, url, message: context.l10n.linkCopied);

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
