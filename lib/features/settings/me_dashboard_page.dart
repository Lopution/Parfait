import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../app/icons/app_icons.dart';
import '../../app/layout/content_widths.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/me_workspace_facade.dart';
import '../../app/navigation/route_facade.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/master_detail_workspace.dart';
import '../../app/widgets/settings/settings_group.dart';
import '../../app/widgets/settings/settings_tile.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../app/window/desktop_command_bar_scope.dart'
    show DesktopCommandBarScope;
import '../../core/auth/account_store.dart';
import '../../core/download/download_providers.dart';
import '../../core/download/download_task.dart' show isTerminal;
import '../../core/localnovel/local_novel_store.dart';
import '../../core/navigation/home_destination.dart';
import '../../core/platform/package_info_provider.dart';
import '../../core/profile/profile_feed_controller.dart';
import '../../core/profile/profile_models.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/user/user_detail_controller.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import '../../core/user/user_store.dart';
import '../../core/watchlater/watch_later_store.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../l10n/context.dart';
import 'me_account_header.dart';
import 'me_panes.dart';
import 'me_recent_history.dart';
import 'pages/download_tasks_page.dart';
import 'settings_catalog.dart';
import 'settings_helpers.dart';
import 'settings_page.dart' show settingsPageIcons;

enum _MeSection {
  bookmarks,
  following,
  watchlist,
  novelMarkers,
  history,
  watchLater,
  localNovels,
  downloads,
}

/// The "me" destination, YouTube's way: who is signed in, what they saw
/// last, the places of their own content as a list, then settings and
/// about. Content comes first — it is what the page is opened for.
class MeDashboardPage extends ConsumerStatefulWidget {
  const MeDashboardPage({super.key});

  @override
  ConsumerState<MeDashboardPage> createState() => _MeDashboardPageState();
}

class _MeDashboardPageState extends ConsumerState<MeDashboardPage> {
  /// Preserves recent history state (keep-alive covers & reorder animations)
  /// across narrow dashboard rebuilds.
  final _historyKey = GlobalKey();
  final _detailNavigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'me-detail',
  );
  _MeSection _selectedSection = _MeSection.bookmarks;
  _MeSection? _activeDetailSection;
  bool _detailCanHandlePop = false;
  bool _hasBeenVisible = false;

  void _selectSection(_MeSection section) {
    if (section == _selectedSection && _activeDetailSection == section) return;
    setState(() {
      _selectedSection = section;
      _activeDetailSection = section;
      _detailCanHandlePop = false;
    });
    final navigator = _detailNavigatorKey.currentState;
    if (navigator == null) return;
    unawaited(
      navigator.pushAndRemoveUntil<void>(
        _buildDetailRoute(section),
        (_) => false,
      ),
    );
  }

  Route<dynamic> _buildDetailRoute(_MeSection section, {bool instant = false}) {
    return PageRouteBuilder<void>(
      settings: RouteSettings(name: 'me/${section.name}'),
      transitionDuration: instant
          ? Duration.zero
          : MotionTokens.resolve(context, MotionTokens.desktopPageTransition),
      reverseTransitionDuration: instant
          ? Duration.zero
          : MotionTokens.resolve(context, MotionTokens.desktopPageTransition),
      pageBuilder: (_, _, _) => _buildWideDetail(section),
      transitionsBuilder: (_, animation, _, child) {
        final isReversing = animation.status == AnimationStatus.reverse;
        final curved = animation.drive(
          CurveTween(
            curve: isReversing
                ? MotionTokens.stateFadeCurve.flipped
                : MotionTokens.stateFadeCurve,
          ),
        );
        return IgnorePointer(
          ignoring: isReversing,
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
  }

  Widget _buildWideDetail(_MeSection section) {
    return switch (section) {
      _MeSection.bookmarks => const MeBookmarksPane(
        filterBarBuilder: profileFilterBar,
        illustFeedBuilder: profileIllustFeed,
        novelFeedBuilder: profileNovelFeed,
      ),
      _MeSection.following => const MeFollowingPane(
        filterBarBuilder: profileFilterBar,
        userFeedBuilder: profileUserFeed,
      ),
      _MeSection.watchlist => const WatchlistPage(),
      _MeSection.novelMarkers => const NovelMarkersPage(),
      _MeSection.history => const HistoryPage(),
      _MeSection.watchLater => const WatchLaterPage(),
      _MeSection.localNovels => const LocalNovelsPage(),
      _MeSection.downloads => const DownloadTasksPage(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    if (TickerMode.valuesOf(context).enabled && (route?.isCurrent ?? true)) {
      _hasBeenVisible = true;
    }
    final accounts = ref.watch(accountStoreProvider);
    final usable = accounts.value?.usableCurrent;
    if (usable != null && _hasBeenVisible) {
      ref.watch(userDetailControllerProvider(usable.userId));
    }
    final userDetail = usable == null
        ? null
        : ref.watch(userStoreProvider.select((users) => users[usable.userId]));
    final detail = userDetail != null && userDetail.hasDetail
        ? userDetail
        : null;
    final desktopOwned = DesktopCommandBarScope.isActiveOf(context);
    final wide = MasterDetailWorkspace.canDisplay(context);
    return MeNetworkScope(
      activated: _hasBeenVisible,
      child: RefreshActionAnchor(
        onRefresh: () {
          ref.invalidate(meRecentHistoryProvider);
          ref.invalidate(_downloadStatsProvider);
          ref.invalidate(watchLaterStoreProvider);
          ref.invalidate(localNovelStoreProvider);
          if (usable != null && _hasBeenVisible) {
            ref.invalidate(userDetailControllerProvider(usable.userId));
            ref.invalidate(
              profileIllustFeedProvider(
                ProfileFeedKey(
                  userId: usable.userId,
                  kind: ProfileFeedKind.bookmarks,
                  workType: UserWorkType.illust,
                  restrict: UserRestrict.public,
                ),
              ),
            );
          }
          unawaited(ref.read(accountStoreProvider.notifier).reload());
        },
        child: wide
            ? _wideBody(
                context,
                accounts,
                detail: detail,
                desktopOwned: desktopOwned,
              )
            : Scaffold(
                // Root pages own no inline composer: leaving the default `true`
                // would subscribe this whole subtree to per-frame viewInsets
                // churn every time the IME animates — a relayout storm across
                // all five live branches.
                resizeToAvoidBottomInset: false,
                appBar: desktopOwned
                    ? null
                    : AppTopBar(
                        contentWidth: ContentWidths.settings,
                        title: Text(context.l10n.homeMe),
                        actions: [
                          IconButton(
                            tooltip: context.l10n.settingsTitle,
                            icon: const Icon(AppIcons.settings),
                            onPressed: () =>
                                openSettingsPage(context, settingsIndexPath),
                          ),
                        ],
                      ),
                body: _narrowBody(context, accounts, detail: detail),
              ),
      ),
    );
  }

  Widget _narrowBody(
    BuildContext context,
    AsyncValue<AccountState> accounts, {
    required UserEntity? detail,
  }) {
    void reload() => ref.read(accountStoreProvider.notifier).reload();
    if (accounts.hasError) {
      return SettingsLoadError(
        error: accounts.error!,
        onRetry: reload,
        messageKey: 'accountReadFailed',
      );
    }
    if (accounts.isLoading && !accounts.hasValue) return const FeedLoading();
    final state = accounts.value;
    if (state?.status == AccountStatus.failure) {
      return SettingsLoadError(
        error: state?.error ?? StateError('account state unavailable'),
        onRetry: reload,
        messageKey: 'accountReadFailed',
      );
    }
    return settingsNarrowBody(
      ListView(
        padding: const EdgeInsets.only(
          top: FuncSpacing.sm,
          bottom: FuncSpacing.xl,
        ),
        children: [
          MeAccountHeader(account: state?.current, detail: detail),
          MeRecentHistory(key: _historyKey, showEmptyCard: true),
          _MeNavGroups(
            signedIn: state?.usableCurrent != null,
            detail: detail,
            includeSettingsEntries: true,
          ),
          const FuncNavBarSpacer(),
        ],
      ),
    );
  }

  Widget _wideBody(
    BuildContext context,
    AsyncValue<AccountState> accounts, {
    required UserEntity? detail,
    required bool desktopOwned,
  }) {
    void reload() => ref.read(accountStoreProvider.notifier).reload();
    if (accounts.hasError) {
      return Scaffold(
        appBar: desktopOwned
            ? null
            : AppTopBar(
                contentWidth: ContentWidths.settings,
                title: Text(context.l10n.homeMe),
              ),
        body: SettingsLoadError(
          error: accounts.error!,
          onRetry: reload,
          messageKey: 'accountReadFailed',
        ),
      );
    }
    if (accounts.isLoading && !accounts.hasValue) {
      return Scaffold(
        appBar: desktopOwned
            ? null
            : AppTopBar(
                contentWidth: ContentWidths.settings,
                title: Text(context.l10n.homeMe),
              ),
        body: const FeedLoading(),
      );
    }
    final state = accounts.value;
    if (state?.status == AccountStatus.failure) {
      return Scaffold(
        appBar: desktopOwned
            ? null
            : AppTopBar(
                contentWidth: ContentWidths.settings,
                title: Text(context.l10n.homeMe),
              ),
        body: SettingsLoadError(
          error: state?.error ?? StateError('account state unavailable'),
          onRetry: reload,
          messageKey: 'accountReadFailed',
        ),
      );
    }
    final signedIn = state?.usableCurrent != null;
    final hideRailShortcuts = desktopOwned;
    var effectiveSection = _selectedSection;
    if (hideRailShortcuts &&
        (effectiveSection == _MeSection.bookmarks ||
            effectiveSection == _MeSection.downloads)) {
      effectiveSection = _MeSection.following;
    }
    if (!signedIn && effectiveSection == _MeSection.novelMarkers) {
      effectiveSection = hideRailShortcuts
          ? _MeSection.following
          : _MeSection.bookmarks;
    }
    if (effectiveSection != _selectedSection ||
        (_activeDetailSection != null &&
            _activeDetailSection != effectiveSection)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_activeDetailSection != null &&
            _activeDetailSection != effectiveSection) {
          _selectSection(effectiveSection);
        } else if (_selectedSection != effectiveSection) {
          setState(() => _selectedSection = effectiveSection);
        }
      });
    }
    return PopScope(
      canPop: !_detailCanHandlePop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_detailNavigatorKey.currentState?.maybePop());
      },
      child: MasterDetailWorkspace(
        key: const ValueKey('me-wide-dashboard'),
        title: Text(context.l10n.homeMe),
        masterTop: MeCompactAccountHeader(
          account: state?.current,
          detail: detail,
        ),
        masterBody: ListView(
          padding: const EdgeInsets.only(
            top: FuncSpacing.xs,
            bottom: FuncSpacing.xl,
          ),
          children: [
            _MeNavGroups(
              signedIn: signedIn,
              detail: detail,
              selected: effectiveSection,
              includeSettingsEntries: !desktopOwned,
              includeRailShortcuts: !hideRailShortcuts,
              onSelectSection: _selectSection,
            ),
          ],
        ),
        detail: SettingsDetailScope(
          onPush: (location) =>
              GoRouter.maybeOf(context)?.push<void>(location) ??
              Future<void>.value(),
          child: HeroControllerScope.none(
            child: NotificationListener<NavigationNotification>(
              onNotification: (notification) {
                final next = notification.canHandlePop;
                if (_detailCanHandlePop != next) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _detailCanHandlePop != next) {
                      setState(() => _detailCanHandlePop = next);
                    }
                  });
                }
                return true;
              },
              child: Navigator(
                key: _detailNavigatorKey,
                onGenerateInitialRoutes: (_, _) {
                  _activeDetailSection = effectiveSection;
                  return [_buildDetailRoute(effectiveSection, instant: true)];
                },
                onGenerateRoute: (_) => _buildDetailRoute(effectiveSection),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

typedef _DownloadStats = ({int active, int total});

/// Live active and total download counts; emits only when either count changes
/// so progress ticks never rebuild the dashboard rows.
final _downloadStatsProvider = StreamProvider.autoDispose<_DownloadStats>((
  ref,
) async* {
  final manager = ref.watch(downloadManagerProvider);
  _DownloadStats snapshot() {
    final tasks = manager.tasks;
    var active = 0;
    for (final task in tasks) {
      if (!isTerminal(task.status)) active++;
    }
    return (active: active, total: tasks.length);
  }

  var last = snapshot();
  yield last;
  await for (final _ in manager.changes) {
    final next = snapshot();
    if (next == last) continue;
    yield last = next;
  }
});

String? _joinSubtitleParts(Iterable<String?> parts) {
  final clean = [
    for (final part in parts)
      if (part != null && part.trim().isNotEmpty) part.trim(),
  ];
  if (clean.isEmpty) return null;
  return clean.join(' ·\u00A0');
}

/// Shared data-driven navigation groups for both the narrow Me dashboard
/// (`onSelectSection == null`, push navigation + Settings/About summaries) and
/// the wide [MasterDetailWorkspace] left rail (`onSelectSection != null`,
/// inline section selection with `showChevron: false`).
class _MeNavGroups extends ConsumerWidget {
  const _MeNavGroups({
    required this.signedIn,
    required this.detail,
    required this.includeSettingsEntries,
    this.includeRailShortcuts = true,
    this.selected,
    this.onSelectSection,
  });

  final bool signedIn;
  final UserEntity? detail;
  final bool includeSettingsEntries;
  final bool includeRailShortcuts;
  final _MeSection? selected;
  final ValueChanged<_MeSection>? onSelectSection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final wide = onSelectSection != null;
    final downloadStats =
        ref.watch(_downloadStatsProvider).value ?? (active: 0, total: 0);
    final watchLaterCount = ref.watch(watchLaterStoreProvider).value?.length;
    final localNovelsCount = ref.watch(localNovelStoreProvider).value?.length;
    final watchlistEntries = ref.watch(watchlistStoreProvider);
    final activeWatchlist = watchlistEntries.values
        .where((e) => e.shown)
        .length;
    final offBar = ref.watch(homeArrangementProvider).hidden;
    final resolvedDetail = signedIn ? detail : null;

    String? settingsSubtitle;
    if (!wide && includeSettingsEntries) {
      final appSettings = ref.watch(settingsProvider).value;
      settingsSubtitle = appSettings == null
          ? l10n.settingsBrowseHint
          : _joinSubtitleParts([
                  themeModeLabel(context, appSettings.themeCode),
                  languageDisplayName(appSettings.languageTag),
                ]) ??
                l10n.settingsBrowseHint;
    }

    String? countText(int? count) =>
        count != null && count > 0 ? AppFormat.count(context, count) : null;

    Widget sectionTile({
      required _MeSection section,
      required IconData icon,
      IconData? selectedIcon,
      required String title,
      String? trailingText,
      Widget? trailingBadge,
      required VoidCallback onPush,
    }) => SettingsTile.topLevel(
      icon: icon,
      selectedIcon: wide ? selectedIcon : null,
      title: title,
      trailingText: trailingText,
      trailingBadge: trailingBadge,
      selected: wide && selected == section,
      showChevron: !wide,
      onTap: wide ? () => onSelectSection!(section) : onPush,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          title: Text(l10n.settingsGroupLibrary),
          children: [
            if (includeRailShortcuts)
              sectionTile(
                section: _MeSection.bookmarks,
                icon: AppIcons.heart,
                selectedIcon: AppIcons.heartFilled,
                title: l10n.profileBookmarked,
                trailingText: countText(
                  resolvedDetail?.totalIllustBookmarksPublic,
                ),
                onPush: () => unawaited(openMe(context, tab: MeTab.bookmarks)),
              ),
            sectionTile(
              section: _MeSection.following,
              icon: AppIcons.users,
              title: l10n.profileFollowing,
              trailingText: countText(resolvedDetail?.totalFollowUsers),
              onPush: () => unawaited(openMe(context, tab: MeTab.following)),
            ),
            sectionTile(
              section: _MeSection.watchlist,
              icon: AppIcons.watchlist,
              title: l10n.watchlistTitle,
              trailingText: countText(activeWatchlist),
              onPush: () => unawaited(openWatchlist(context)),
            ),
            // Pixiv keeps novel markers with the signed-in account.
            if (signedIn)
              sectionTile(
                section: _MeSection.novelMarkers,
                icon: AppIcons.novelMarkers,
                title: l10n.novelMarkers,
                onPush: () => unawaited(openNovelMarkers(context)),
              ),
            for (final destination in HomeDestination.values)
              if (offBar.contains(destination))
                SettingsTile.topLevel(
                  icon: homeDestinationIcon(destination),
                  title: homeDestinationLabel(context, destination),
                  showChevron: !wide,
                  onTap: () => openHomeDestination(context, destination),
                ),
          ],
        ),
        SettingsGroup(
          title: Text(l10n.settingsGroupData),
          children: [
            if (wide)
              sectionTile(
                section: _MeSection.history,
                icon: AppIcons.history,
                title: l10n.historySettings,
                onPush: () => unawaited(openHistory(context)),
              ),
            sectionTile(
              section: _MeSection.watchLater,
              icon: AppIcons.watchLater,
              selectedIcon: AppIcons.watchLaterFilled,
              title: l10n.watchLaterTitle,
              trailingText: countText(watchLaterCount),
              onPush: () => unawaited(openWatchLater(context)),
            ),
            sectionTile(
              section: _MeSection.localNovels,
              icon: AppIcons.localNovel,
              title: l10n.localNovelsTitle,
              trailingText: countText(localNovelsCount),
              onPush: () => unawaited(openLocalNovels(context)),
            ),
            if (includeRailShortcuts)
              sectionTile(
                section: _MeSection.downloads,
                icon: AppIcons.downloading,
                title: l10n.downloaderSettings,
                trailingText: downloadStats.active == 0
                    ? countText(downloadStats.total)
                    : null,
                trailingBadge: Badge(
                  isLabelVisible: downloadStats.active > 0,
                  label: Text(AppFormat.count(context, downloadStats.active)),
                ),
                onPush: () => unawaited(openDownloadTasks(context)),
              ),
          ],
        ),
        if (includeSettingsEntries)
          SettingsGroup(
            title: const Text('Parfait'),
            children: [
              SettingsTile.topLevel(
                icon: AppIcons.settings,
                title: l10n.settingsTitle,
                subtitle: settingsSubtitle == null
                    ? null
                    : Text(settingsSubtitle),
                showChevron: !wide,
                onTap: () => openSettingsPage(context, settingsIndexPath),
              ),
              SettingsTile.topLevel(
                icon: settingsPageIcons[SettingsPageRef.about]!,
                title: l10n.aboutSettings,
                subtitle: wide ? null : const _MeVersionSummary(),
                showChevron: !wide,
                onTap: () =>
                    openSettingsPage(context, SettingsPageRef.about.path),
              ),
            ],
          ),
      ],
    );
  }
}

class _MeVersionSummary extends ConsumerWidget {
  const _MeVersionSummary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(packageInfoProvider).asData?.value.version;
    return Text(version ?? '—');
  }
}
