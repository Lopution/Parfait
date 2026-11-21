import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, ScrollCacheExtent;

import '../../app/layout/content_widths.dart';
import '../../app/layout/deferred_cache_scroll_view.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/master_detail_workspace.dart';
import '../../app/widgets/settings/settings_anchor.dart';
import '../../app/widgets/settings/settings_group.dart';
import '../../app/widgets/settings/settings_tile.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../core/auth/account_store.dart';
import '../../core/translation/translation_service.dart';
import '../../core/debug/frame_probe.dart';
import '../../core/mute/mute_store.dart';
import '../../core/navigation/route_observer.dart';
import '../../core/platform/package_info_provider.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/settings/shared_preferences.dart';
import '../../l10n/context.dart';
import 'network_probe_page.dart';
import 'network_settings_page.dart';
import 'pages/about_settings_page.dart';
import 'pages/account_settings_page.dart';
import 'pages/backup_settings_page.dart';
import 'pages/bottom_bar_settings_page.dart';
import 'pages/browse_settings_page.dart';
import 'pages/download_destination_page.dart';
import 'pages/download_settings_page.dart';
import 'pages/download_tasks_page.dart';
import 'pages/frame_probe_page.dart';
import 'pages/language_settings_page.dart';
import 'pages/motion_settings_page.dart';
import 'pages/muted_items_page.dart';
import 'pages/navigation_settings_page.dart';
import 'pages/theme_settings_page.dart';
import 'pages/translate_settings_page.dart';
import 'pages/translation_credentials_page.dart';
import 'settings_catalog.dart';
import 'settings_helpers.dart';
import '../../app/icons/app_icons.dart';
import '../../app/icons/ui_icons.dart';

export 'pages/about_settings_page.dart';
export 'pages/account_settings_page.dart';
export 'pages/backup_settings_page.dart';
export 'pages/bottom_bar_settings_page.dart';
export 'pages/muted_items_page.dart';
export 'pages/browse_settings_page.dart';
export 'pages/download_settings_page.dart';
export 'pages/download_destination_page.dart';
export 'pages/download_tasks_page.dart';
export 'pages/language_settings_page.dart';
export 'pages/motion_settings_page.dart';
export 'pages/navigation_settings_page.dart';
export 'pages/theme_settings_page.dart';
export 'pages/translate_settings_page.dart';

/// Wraps a settings leaf route so wide desktop/tablet viewports open inside
/// [MasterDetailWorkspace] with the target section active rather than dropping
/// into an isolated single-column page.
class SettingsAdaptiveHost extends StatelessWidget {
  const SettingsAdaptiveHost({
    super.key,
    required this.location,
    required this.narrowPage,
  });

  final String location;
  final Widget narrowPage;

  @override
  Widget build(BuildContext context) {
    if (MasterDetailWorkspace.canDisplay(context)) {
      return SettingsPage(initialLocation: location);
    }
    return narrowPage;
  }
}

/// All settings, grouped by intent, with a search over every setting
/// (`/settings/all`, opened from the "me" dashboard or shell rail). While the
/// search has text, its results replace the groups.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.initialLocation});

  /// Optional deep-link location (e.g. `/settings/about`, `/settings/network`,
  /// `/settings/all?section=account`) used to initialize the detail pane on
  /// wide master-detail workspaces.
  final String? initialLocation;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _query = TextEditingController();
  final _indexBodyKey = GlobalKey(debugLabel: 'settings-index-body');
  final _selectedTileKey = GlobalKey(debugLabel: 'settings-selected-tile');
  final _detailNavigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'settings-detail',
  );
  final _draftRegistry = SettingsDraftRegistry();
  late final _detailObserver = _DetailStackObserver(_syncDetailCanPop);
  late SettingsPageRef _selectedPage;
  late String _initialDetailLocation;
  late bool _initialIsNestedChild;
  bool _detailCanPop = false;
  bool _pendingRevealSelected = false;
  int _revealAttempts = 0;

  @override
  void initState() {
    super.initState();
    final target = _resolveInitialTarget(widget.initialLocation);
    _selectedPage = target.rootRef;
    _initialDetailLocation = target.detailLocation;
    _initialIsNestedChild = target.isNestedChild;
    _pendingRevealSelected = _selectedPage != SettingsPageRef.account;
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialLocation != oldWidget.initialLocation &&
        widget.initialLocation != null) {
      final target = _resolveInitialTarget(widget.initialLocation);
      _initialDetailLocation = target.detailLocation;
      _initialIsNestedChild = target.isNestedChild;
      if (MasterDetailWorkspace.canDisplay(context) &&
          _detailNavigatorKey.currentState != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _applyDetailLocation(target.detailLocation);
        });
      } else if (_selectedPage != target.rootRef) {
        setState(() {
          _selectedPage = target.rootRef;
          _pendingRevealSelected = _selectedPage != SettingsPageRef.account;
          _revealAttempts = 0;
        });
      }
    }
  }

  @override
  void dispose() {
    _draftRegistry.dispose();
    _query.dispose();
    super.dispose();
  }

  ({SettingsPageRef rootRef, String detailLocation, bool isNestedChild})
  _resolveInitialTarget(String? rawLocation) {
    if (rawLocation == null || rawLocation.isEmpty) {
      return (
        rootRef: SettingsPageRef.account,
        detailLocation: SettingsPageRef.account.path,
        isNestedChild: false,
      );
    }
    final uri = Uri.parse(rawLocation);
    final section = uri.queryParameters['section'];
    if (section != null && section.isNotEmpty) {
      for (final candidate in SettingsPageRef.values) {
        if (candidate.name == section ||
            candidate.path == '/settings/$section') {
          final root = candidate.parent ?? candidate;
          final focus = uri.queryParameters[focusQuery];
          final loc = focus == null
              ? candidate.path
              : Uri(
                  path: candidate.path,
                  queryParameters: {focusQuery: focus},
                ).toString();
          return (
            rootRef: root,
            detailLocation: loc,
            isNestedChild: candidate.parent != null,
          );
        }
      }
    }
    if (uri.path == '/settings/all' || uri.path == '/settings') {
      return (
        rootRef: SettingsPageRef.account,
        detailLocation: SettingsPageRef.account.path,
        isNestedChild: false,
      );
    }
    final pageRef = _pageRefForPath(uri.path);
    final rootRef =
        pageRef?.parent ??
        pageRef ??
        _rootRefForSubPath(uri.path) ??
        SettingsPageRef.account;
    final isNestedChild =
        (pageRef != null && pageRef.parent != null) ||
        (pageRef == null && _rootRefForSubPath(uri.path) != null);
    return (
      rootRef: rootRef,
      detailLocation: rawLocation,
      isNestedChild: isNestedChild,
    );
  }

  void _syncDetailCanPop() {
    if (!mounted) return;
    final canPop = _detailNavigatorKey.currentState?.canPop() ?? false;
    if (canPop != _detailCanPop) {
      setState(() => _detailCanPop = canPop);
    }
  }

  SettingsPageRef? _pageRefForPath(String path) {
    for (final ref in SettingsPageRef.values) {
      if (ref.path == path) return ref;
    }
    return null;
  }

  SettingsPageRef? _rootRefForSubPath(String path) {
    if (path == '/settings/translate/credentials' ||
        path.startsWith('/settings/translate/credentials/')) {
      return SettingsPageRef.translate;
    }
    if (path == '/settings/about/licenses' ||
        path.startsWith('/settings/about/')) {
      return SettingsPageRef.about;
    }
    if (path == '/settings/tasks') return SettingsPageRef.download;
    return null;
  }

  void _scheduleRevealSelected() {
    if (!_pendingRevealSelected) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _revealSelectedIfReady(),
    );
  }

  void _revealSelectedIfReady() {
    if (!mounted || !_pendingRevealSelected) return;
    final ctx = _selectedTileKey.currentContext;
    if (ctx == null) {
      if (_revealAttempts < 6) {
        _revealAttempts++;
        _scheduleRevealSelected();
      } else {
        _pendingRevealSelected = false;
      }
      return;
    }
    _pendingRevealSelected = false;
    _revealAttempts = 0;
    final renderObject = ctx.findRenderObject();
    if (renderObject == null) return;
    final scrollable = Scrollable.maybeOf(ctx);
    if (scrollable == null) return;
    final viewport = RenderAbstractViewport.maybeOf(renderObject);
    if (viewport == null) return;
    final position = scrollable.position;
    if (!position.hasContentDimensions) return;
    final revealTop = viewport.getOffsetToReveal(renderObject, 0.0).offset;
    final revealBottom = viewport.getOffsetToReveal(renderObject, 1.0).offset;
    if (position.pixels < revealBottom || position.pixels > revealTop) {
      final target = viewport
          .getOffsetToReveal(renderObject, 0.5)
          .offset
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      position.jumpTo(target);
    }
  }

  void _openInDetailPane(String location) {
    if (!_detailCanPop && location == _initialDetailLocation) return;
    if (!_draftRegistry.hasDirtyDraft) return _applyDetailLocation(location);
    unawaited(
      _draftRegistry.confirmDiscardIfDirty(context).then((leave) {
        if (leave && mounted) _applyDetailLocation(location);
      }),
    );
  }

  void _applyDetailLocation(String location) {
    final uri = Uri.parse(location);
    final pageRef = _pageRefForPath(uri.path);
    final rootRef = pageRef?.parent ?? pageRef ?? _rootRefForSubPath(uri.path);
    if (rootRef != null && rootRef != _selectedPage) {
      setState(() {
        _selectedPage = rootRef;
        _pendingRevealSelected = true;
        _revealAttempts = 0;
      });
    }
    final isNestedChild =
        (pageRef != null && pageRef.parent != null) ||
        (pageRef == null && rootRef != null);
    _initialDetailLocation = location;
    _initialIsNestedChild = isNestedChild;
    final navigator = _detailNavigatorKey.currentState;
    if (navigator == null) return;
    if (isNestedChild && rootRef != null) {
      unawaited(
        navigator.pushAndRemoveUntil<void>(
          _buildDetailRoute(rootRef.path, instant: true),
          (_) => false,
        ),
      );
      unawaited(navigator.pushNamed<void>(location));
      return;
    }
    unawaited(navigator.pushNamedAndRemoveUntil<void>(location, (_) => false));
  }

  List<Route<dynamic>> _buildInitialDetailRoutes() {
    if (_initialIsNestedChild && _initialDetailLocation != _selectedPage.path) {
      return [
        _buildDetailRoute(_selectedPage.path, instant: true),
        _buildDetailRoute(_initialDetailLocation, instant: true),
      ];
    }
    return [_buildDetailRoute(_initialDetailLocation, instant: true)];
  }

  Future<void> _pushInDetailPane(String location) {
    final navigator = _detailNavigatorKey.currentState;
    if (navigator == null) return Future<void>.value();
    return navigator.pushNamed<void>(location);
  }

  Route<dynamic> _buildDetailRoute(String location, {bool instant = false}) {
    final uri = Uri.parse(location);
    final page = SettingsFocusScope(
      target: uri.queryParameters[focusQuery],
      child: _buildDetailPage(uri),
    );
    return PageRouteBuilder<void>(
      settings: RouteSettings(name: location),
      transitionDuration: instant
          ? Duration.zero
          : MotionTokens.resolve(context, MotionTokens.desktopPageTransition),
      reverseTransitionDuration: instant
          ? Duration.zero
          : MotionTokens.resolve(context, MotionTokens.desktopPageTransition),
      pageBuilder: (_, _, _) => page,
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

  Widget _buildDetailPage(Uri uri) {
    final path = uri.path;
    if (path == '/settings/translate/credentials' ||
        path.startsWith('/settings/translate/credentials/')) {
      const prefix = '/settings/translate/credentials/';
      final provider = path.startsWith(prefix)
          ? path.substring(prefix.length)
          : '';
      return TranslationCredentialsPage(baidu: provider == 'baidu');
    }
    return switch (path) {
      '/settings/account' => const AccountSettingsPage(),
      '/settings/theme' => const ThemeSettingsPage(),
      '/settings/language' => const LanguageSettingsPage(),
      '/settings/translate' => const TranslateSettingsPage(),
      '/settings/motion' => const MotionSettingsPage(),
      '/settings/browse' => const BrowseSettingsPage(),
      '/settings/navigation' => const NavigationSettingsPage(),
      '/settings/navigation/bottom-bar' => const BottomBarSettingsPage(),
      '/settings/muted' => const MutedItemsPage(),
      '/settings/network' => const NetworkSettingsPage(),
      '/settings/network/probe' => const NetworkProbePage(),
      '/settings/network/advanced' => const NetworkAdvancedSettingsPage(),
      '/settings/download' => const DownloadSettingsPage(),
      '/settings/download/destination' => const DownloadDestinationPage(),
      '/settings/backup' => const BackupSettingsPage(),
      '/settings/tasks' => const DownloadTasksPage(),
      '/settings/about' => const AboutSettingsPage(),
      '/settings/about/licenses' => const LicensesSettingsPage(),
      '/settings/frame-probe' => const FrameProbePage(),
      _ => const AccountSettingsPage(),
    };
  }

  Widget _buildSearchField(
    BuildContext context,
    String query, {
    required EdgeInsetsGeometry padding,
    bool compact = false,
  }) {
    return Padding(
      padding: padding,
      child: SearchBar(
        controller: _query,
        constraints: BoxConstraints(
          minHeight: compact ? 40 : 48,
          maxHeight: compact ? 40 : double.infinity,
        ),
        hintText: context.l10n.settingsSearchHint,
        leading: Icon(AppIcons.search, size: compact ? 19 : null),
        trailing: [
          if (query.isNotEmpty)
            IconButton(
              tooltip: context.l10n.searchClear,
              icon: Icon(UiIcons.close, size: compact ? 18 : null),
              onPressed: () => setState(_query.clear),
            ),
        ],
        onChanged: (_) => setState(() {}),
        textInputAction: TextInputAction.search,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final query = _query.text;
    final masterDetail = MasterDetailWorkspace.canDisplay(context);
    if (masterDetail && _pendingRevealSelected && query.trim().isEmpty) {
      _scheduleRevealSelected();
    }

    final Widget body = KeyedSubtree(
      key: _indexBodyKey,
      child: settings.when(
        loading: () => const FeedLoading(),
        error: (error, _) => SettingsLoadError(
          error: error,
          onRetry: () => ref.read(settingsProvider.notifier).reload(),
        ),
        data: (resolvedSettings) => _SettingsIndexList(
          settings: resolvedSettings,
          query: query,
          selectedPage: masterDetail ? _selectedPage : null,
          selectedTileKey: masterDetail ? _selectedTileKey : null,
          showChevron: !masterDetail,
          onSelectLocation: masterDetail ? _openInDetailPane : null,
          header: masterDetail
              ? null
              : _buildSearchField(
                  context,
                  query,
                  padding: const EdgeInsets.fromLTRB(
                    FuncSpacing.lg,
                    0,
                    FuncSpacing.lg,
                    FuncSpacing.sm,
                  ),
                ),
        ),
      ),
    );

    if (!masterDetail) {
      return Scaffold(
        appBar: AppTopBar(
          contentWidth: ContentWidths.settings,
          title: Text(context.l10n.settingsTitle),
        ),
        body: body,
      );
    }

    return settingsMasterPopScope(
      draftRegistry: _draftRegistry,
      detailCanPop: _detailCanPop,
      detailNavigatorKey: _detailNavigatorKey,
      child: MasterDetailWorkspace(
        title: Text(context.l10n.settingsTitle),
        masterTop: _buildSearchField(
          context,
          query,
          compact: true,
          padding: const EdgeInsets.fromLTRB(
            FuncSpacing.md,
            FuncSpacing.sm,
            FuncSpacing.md,
            FuncSpacing.xs,
          ),
        ),
        masterBody: body,
        detail: SettingsDetailScope(
          onPush: _pushInDetailPane,
          draftRegistry: _draftRegistry,
          child: Navigator(
            key: _detailNavigatorKey,
            observers: [_detailObserver],
            onGenerateInitialRoutes: (navigator, initialRoute) =>
                _buildInitialDetailRoutes(),
            onGenerateRoute: (routeSettings) => _buildDetailRoute(
              routeSettings.name ?? SettingsPageRef.account.path,
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailStackObserver extends NavigatorObserver {
  _DetailStackObserver(this.onChanged);

  final VoidCallback onChanged;

  void _notify() {
    WidgetsBinding.instance.addPostFrameCallback((_) => onChanged());
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _notify();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _notify();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _notify();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _notify();
}

/// The row icon of each settings page, on the index and in the settings
/// fold of the "me" page.
const settingsPageIcons = <SettingsPageRef, IconData>{
  SettingsPageRef.account: AppIcons.accountManage,
  SettingsPageRef.theme: AppIcons.palette,
  SettingsPageRef.language: AppIcons.globe,
  SettingsPageRef.translate: AppIcons.translate,
  SettingsPageRef.motion: AppIcons.motion,
  SettingsPageRef.browse: AppIcons.illust,
  SettingsPageRef.navigation: AppIcons.layoutNav,
  SettingsPageRef.muted: AppIcons.ban,
  SettingsPageRef.network: AppIcons.network,
  SettingsPageRef.download: AppIcons.download,
  SettingsPageRef.backup: AppIcons.backup,
  SettingsPageRef.about: AppIcons.info,
  SettingsPageRef.frameProbe: AppIcons.gauge,
};

List<Widget> _searchResultGroups(
  BuildContext context,
  List<SettingsSearchResult> results, {
  bool showChevron = true,
  ValueChanged<String>? onSelectLocation,
}) => [
  SettingsGroup(
    children: [
      for (final result in results)
        SettingsTile(
          title: result.label,
          showChevron: showChevron,
          subtitle: result.path.isEmpty ? null : Text(result.path.join(' › ')),
          onTap: () {
            final select = onSelectLocation;
            if (select != null) {
              select(result.location);
            } else {
              openSettingsPage(context, result.location);
            }
          },
        ),
    ],
  ),
];

class _SettingsIndexList extends ConsumerWidget {
  const _SettingsIndexList({
    required this.settings,
    required this.query,
    this.selectedPage,
    this.selectedTileKey,
    this.showChevron = true,
    this.onSelectLocation,
    this.header,
  });

  final AppSettings settings;
  final String query;
  final SettingsPageRef? selectedPage;
  final GlobalKey? selectedTileKey;
  final bool showChevron;
  final ValueChanged<String>? onSelectLocation;
  final Widget? header;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trimmedQuery = query.trim();
    final List<Widget> items;
    if (trimmedQuery.isEmpty) {
      items = [
        ..._indexGroups(
          context,
          ref,
          settings,
          selectedPage: selectedPage,
          selectedTileKey: selectedTileKey,
          showChevron: showChevron,
          onSelectLocation: onSelectLocation,
        ),
        _DeveloperSettingsGroup(
          selected: selectedPage == SettingsPageRef.frameProbe,
          selectedTileKey: selectedPage == SettingsPageRef.frameProbe
              ? selectedTileKey
              : null,
          showChevron: showChevron,
          onSelectLocation: onSelectLocation,
        ),
      ];
    } else {
      final results = searchSettings(context.l10n, query);
      items = results.isEmpty
          ? [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: FuncSpacing.xxl),
                child: FeedEmpty(
                  icon: AppIcons.searchOff,
                  title: context.l10n.settingsSearchEmpty,
                ),
              ),
            ]
          : _searchResultGroups(
              context,
              results,
              showChevron: showChevron,
              onSelectLocation: onSelectLocation,
            );
    }

    return NotificationListener<ScrollStartNotification>(
      onNotification: (notification) {
        if (trimmedQuery.isNotEmpty && notification.dragDetails != null) {
          FocusManager.instance.primaryFocus?.unfocus();
        }
        return false;
      },
      child: settingsNarrowBody(
        SmoothWheelScroll(
          builder: (context, controller, physics) => DeferredCacheListView(
            controller: controller,
            physics: physics,
            // A bounded ~15-tile list: prebuilding it, from the second frame,
            // keeps maxScrollExtent stable during a fling.
            scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
            padding: const EdgeInsets.only(
              top: FuncSpacing.xs,
              bottom: FuncSpacing.xl,
            ),
            children: [?header, ...items],
          ),
        ),
      ),
    );
  }
}

/// The settings pages grouped by intent, as the index lists them, each
/// row with its monochrome icon and live summary.
List<Widget> _indexGroups(
  BuildContext context,
  WidgetRef ref,
  AppSettings settings, {
  SettingsPageRef? selectedPage,
  GlobalKey? selectedTileKey,
  bool showChevron = true,
  ValueChanged<String>? onSelectLocation,
}) {
  final l10n = context.l10n;
  final groups = <({String title, List<SettingsPageRef> pages})>[
    (title: l10n.accountSettings, pages: const [SettingsPageRef.account]),
    (
      title: l10n.settingsGroupAppearance,
      pages: const [
        SettingsPageRef.theme,
        SettingsPageRef.language,
        SettingsPageRef.translate,
        SettingsPageRef.motion,
      ],
    ),
    (
      title: l10n.settingsGroupBrowse,
      pages: const [
        SettingsPageRef.browse,
        SettingsPageRef.navigation,
        SettingsPageRef.muted,
      ],
    ),
    (
      title: l10n.settingsGroupNetwork,
      pages: const [SettingsPageRef.network, SettingsPageRef.download],
    ),
    (title: l10n.settingsGroupData, pages: const [SettingsPageRef.backup]),
    (title: 'Parfait', pages: const [SettingsPageRef.about]),
  ];
  return [
    for (final group in groups)
      SettingsGroup(
        title: Text(group.title),
        children: [
          for (final page in group.pages)
            KeyedSubtree(
              key: selectedPage == page ? selectedTileKey : null,
              child: SettingsTile.topLevel(
                setting: page,
                icon: settingsPageIcons[page],
                selectedIcon: page == SettingsPageRef.about
                    ? AppIcons.infoFilled
                    : null,
                subtitle: _pageSummary(context, ref, settings, page),
                selected: selectedPage == page,
                showChevron: showChevron,
                onTap: () {
                  final select = onSelectLocation;
                  if (select != null) {
                    select(page.path);
                  } else {
                    openSettingsPage(context, page.path);
                  }
                },
              ),
            ),
        ],
      ),
  ];
}

/// The summary under a settings page's row. Root summaries answer "what
/// is the current value" (Android summary convention): concrete values,
/// never a description of the title. Pages without one natural value
/// (browse, navigation, backup) carry a static hint instead.
Widget _pageSummary(
  BuildContext context,
  WidgetRef ref,
  AppSettings settings,
  SettingsPageRef page,
) {
  final l10n = context.l10n;
  switch (page) {
    case SettingsPageRef.account:
      final account = ref.watch(accountStoreProvider).value?.current;
      return Text(account?.name ?? l10n.signedOut);
    case SettingsPageRef.theme:
      return Text(themeModeLabel(context, settings.themeCode));
    case SettingsPageRef.language:
      return Text(languageDisplayName(settings.languageTag));
    case SettingsPageRef.translate:
      return _TranslationSummary(provider: settings.translationProvider);
    case SettingsPageRef.motion:
      return Text(
        settings.reduceMotion
            ? l10n.reduceMotion
            : animationSpeedLabel(context, settings.animationSpeed),
      );
    case SettingsPageRef.browse:
      return Text(l10n.settingsBrowseHint);
    case SettingsPageRef.navigation:
      return Text(l10n.settingsNavigationHint);
    case SettingsPageRef.muted:
      final muted = ref.watch(muteStoreProvider);
      final count = muted.tags.length + muted.users.length + muted.works.length;
      return Text(
        count == 0 ? l10n.mutedEmpty : l10n.settingsMutedSummary(count),
      );
    case SettingsPageRef.network:
      return Text(networkModeLabel(context, settings.networkMode));
    case SettingsPageRef.download:
      return Text(
        '${namingPresetLabel(context, settings.namingRule.preset)}\n'
        '${downloadDestinationLabel(context, settings.downloadDestination)}',
      );
    case SettingsPageRef.backup:
      return Text(l10n.backupHint);
    case SettingsPageRef.about:
      return const _VersionSummary();
    default:
      throw ArgumentError.value(page, 'page', 'not on the settings index');
  }
}

/// The developer group (frame probe), under the settings on the index and
/// on the Me page; nothing while it is locked.
///
/// The frame probe is a diagnostics tool, not a preference: it ships in
/// every build but stays hidden until the about-page gesture unlocks it.
/// Builds that can record ([FrameProbe.available]: non-release, or a
/// release with the `PIXIV_FRAME_PROBE` dart-define for signed measurement
/// packages) show it unlocked; default release builds are unchanged.
class _DeveloperSettingsGroup extends ConsumerWidget {
  const _DeveloperSettingsGroup({
    this.selected = false,
    this.selectedTileKey,
    this.showChevron = true,
    this.onSelectLocation,
  });

  final bool selected;
  final GlobalKey? selectedTileKey;
  final bool showChevron;
  final ValueChanged<String>? onSelectLocation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(developerOptionsProvider) && !FrameProbe.available) {
      return const SizedBox.shrink();
    }
    const probe = SettingsPageRef.frameProbe;
    return SettingsGroup(
      title: Text(context.l10n.settingsGroupDeveloper),
      children: [
        KeyedSubtree(
          key: selected ? selectedTileKey : null,
          child: SettingsTile.topLevel(
            setting: probe,
            icon: settingsPageIcons[probe],
            selected: selected,
            showChevron: showChevron,
            onTap: () {
              final select = onSelectLocation;
              if (select != null) {
                select(probe.path);
              } else {
                openSettingsPage(context, probe.path);
              }
            },
          ),
        ),
      ],
    );
  }
}

/// Translation summary = provider label, plus the configured/unconfigured
/// state for credential-backed providers (D8). The existence probe only
/// checks key presence — secret values are never read for display.
class _TranslationSummary extends ConsumerStatefulWidget {
  const _TranslationSummary({required this.provider});

  final TranslationProvider provider;

  @override
  ConsumerState<_TranslationSummary> createState() =>
      _TranslationSummaryState();
}

class _TranslationSummaryState extends ConsumerState<_TranslationSummary>
    with RouteAware {
  Future<bool>? _configured;
  RouteObserver<ModalRoute<dynamic>>? _observer;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _configured = _probe();
  }

  /// Key-existence probe for the *current* provider (D8) — answers
  /// "configured?" without loading secret values.
  Future<bool>? _probe() {
    final store = ref.read(translationCredentialStoreProvider);
    return switch (widget.provider) {
      TranslationProvider.baidu => store.hasBaidu(),
      TranslationProvider.translationLlm => store.hasLlm(),
      _ => null,
    };
  }

  @override
  void didUpdateWidget(_TranslationSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A provider switch must not keep showing the previous provider's
    // credential state under the new label.
    if (oldWidget.provider != widget.provider) {
      _configured = _probe();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = RouteObserverScope.maybeOf(context);
    final route = ModalRoute.of(context);
    if (identical(observer, _observer) && identical(route, _route)) return;
    _unsubscribe();
    _observer = observer;
    _route = route;
    if (observer != null && route != null) {
      observer.subscribe(this, route);
    }
  }

  void _unsubscribe() {
    final observer = _observer;
    final route = _route;
    if (observer != null && route != null) observer.unsubscribe(this);
  }

  /// The credentials page may have written or cleared keys while it
  /// covered this route — re-probe when the settings root resurfaces.
  @override
  void didPopNext() {
    final probe = _probe();
    // Block body: an arrow closure would return the Future to setState,
    // which asserts against exactly that.
    setState(() {
      _configured = probe;
    });
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = translationProviderLabel(context, widget.provider);
    final configured = _configured;
    if (configured == null) return Text(label);
    return FutureBuilder<bool>(
      future: configured,
      builder: (context, snapshot) {
        final state = snapshot.data;
        // Pending or a store error degrades to the bare provider label:
        // the credentials page owns surfacing store failures; the summary
        // never invents a state.
        if (state == null) return Text(label);
        final l10n = context.l10n;
        final status = state
            ? l10n.settingsCredentialConfigured
            : l10n.settingsCredentialNotConfigured;
        return Text('$label · $status');
      },
    );
  }
}

/// Version string under the about entry, shown as the about page shows it:
/// the platform package's version, without the build number.
class _VersionSummary extends ConsumerWidget {
  const _VersionSummary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(packageInfoProvider).asData?.value.version;
    return Text(version ?? '—');
  }
}
