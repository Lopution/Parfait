import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../app/layout/app_breakpoints.dart';
import '../../app/layout/content_widths.dart';
import '../../app/layout/deferred_cache_scroll_view.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/home_shell_metrics.dart';
import '../../app/theme/category_colors.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/settings/settings_anchor.dart';
import '../../app/widgets/settings/settings_group.dart';
import '../../app/widgets/settings/settings_tile.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/auth/account_store.dart';
import '../../core/translation/translation_service.dart';
import '../../core/debug/frame_probe.dart';
import '../../core/mute/mute_store.dart';
import '../../core/navigation/route_observer.dart';
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

/// All settings, grouped by intent, with a search over every setting
/// (`/settings/all`, opened from the "me" dashboard). While the search has
/// text, its results replace the groups.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  static const double _masterPaneWidth = 336;

  final _query = TextEditingController();
  final _detailNavigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'settings-detail',
  );
  late final _detailObserver = _DetailStackObserver(_syncDetailCanPop);
  SettingsPageRef _selectedPage = SettingsPageRef.account;
  bool _detailCanPop = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  static bool _useMasterDetail(BuildContext context) {
    final contentWidth = HomeShellChrome.contentSizeOf(context).width;
    final viewport = MediaQuery.sizeOf(context);
    return contentWidth >= AppBreakpoints.expanded &&
        viewport.width >= viewport.height * 0.75;
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
    if (path.startsWith('/settings/translate/credentials/')) {
      return SettingsPageRef.translate;
    }
    if (path == '/settings/about/licenses') return SettingsPageRef.about;
    if (path == '/settings/tasks') return SettingsPageRef.download;
    return null;
  }

  void _openInDetailPane(String location) {
    final uri = Uri.parse(location);
    final pageRef = _pageRefForPath(uri.path);
    final rootRef = pageRef?.parent ?? pageRef ?? _rootRefForSubPath(uri.path);
    if (rootRef != null && rootRef != _selectedPage) {
      setState(() => _selectedPage = rootRef);
    }
    final navigator = _detailNavigatorKey.currentState;
    if (navigator == null) return;
    final isNestedChild =
        (pageRef != null && pageRef.parent != null) ||
        (pageRef == null && rootRef != null);
    if (isNestedChild && rootRef != null) {
      unawaited(
        navigator.pushNamedAndRemoveUntil<void>(rootRef.path, (_) => false),
      );
      unawaited(navigator.pushNamed<void>(location));
      return;
    }
    unawaited(navigator.pushNamedAndRemoveUntil<void>(location, (_) => false));
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
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    );
  }

  Widget _buildDetailPage(Uri uri) {
    final path = uri.path;
    if (path.startsWith('/settings/translate/credentials/')) {
      final provider = path.substring('/settings/translate/credentials/'.length);
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
      '/settings/about/licenses' => FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snapshot) => LicensePage(
          applicationName: 'Parfait',
          applicationVersion: snapshot.data?.version,
        ),
      ),
      '/settings/frame-probe' => const FrameProbePage(),
      _ => const AccountSettingsPage(),
    };
  }

  PreferredSizeWidget _buildSearchBar(
    BuildContext context,
    String query, {
    bool narrowWrap = true,
  }) {
    final field = Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        0,
        FuncSpacing.lg,
        FuncSpacing.sm,
      ),
      // The search page's field: one look for every search.
      child: SearchBar(
        controller: _query,
        constraints: const BoxConstraints(minHeight: 48),
        hintText: context.l10n.settingsSearchHint,
        leading: const Icon(Icons.search),
        trailing: [
          if (query.isNotEmpty)
            IconButton(
              tooltip: context.l10n.searchClear,
              icon: const Icon(Icons.close),
              onPressed: () => setState(_query.clear),
            ),
        ],
        onChanged: (_) => setState(() {}),
        textInputAction: TextInputAction.search,
      ),
    );
    return PreferredSize(
      preferredSize: const Size.fromHeight(_searchBarExtent),
      child: narrowWrap ? settingsNarrowBody(field) : field,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final query = _query.text;
    final masterDetail = _useMasterDetail(context);
    final body = settings.when(
      loading: () => const FeedLoading(),
      error: (error, _) => SettingsLoadError(
        error: error,
        onRetry: () => ref.read(settingsProvider.notifier).reload(),
      ),
      data: (settings) => query.trim().isEmpty
          ? _SettingsGroups(
              settings: settings,
              selectedPage: masterDetail ? _selectedPage : null,
              onSelectLocation: masterDetail ? _openInDetailPane : null,
            )
          : _SearchResults(
              query: query,
              onSelectLocation: masterDetail ? _openInDetailPane : null,
            ),
    );

    if (!masterDetail) {
      return Scaffold(
        appBar: AppTopBar(
          contentWidth: ContentWidths.settings,
          title: Text(context.l10n.settingsTitle),
          bottom: _buildSearchBar(context, query),
        ),
        body: body,
      );
    }

    return PopScope(
      canPop: !_detailCanPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_detailNavigatorKey.currentState?.maybePop());
      },
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Row(
          children: [
            SizedBox(
              width: _masterPaneWidth,
              child: Scaffold(
                appBar: AppTopBar(
                  title: Text(context.l10n.settingsTitle),
                  bottom: _buildSearchBar(context, query, narrowWrap: false),
                ),
                body: body,
              ),
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(
              child: SettingsDetailScope(
                onPush: _pushInDetailPane,
                child: Navigator(
                  key: _detailNavigatorKey,
                  observers: [_detailObserver],
                  onGenerateInitialRoutes: (navigator, initialRoute) => [
                    _buildDetailRoute(_selectedPage.path, instant: true),
                  ],
                  onGenerateRoute: (routeSettings) => _buildDetailRoute(
                    routeSettings.name ?? SettingsPageRef.account.path,
                  ),
                ),
              ),
            ),
          ],
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
  SettingsPageRef.account: Icons.manage_accounts_outlined,
  SettingsPageRef.theme: Icons.palette_outlined,
  SettingsPageRef.language: Icons.language,
  SettingsPageRef.translate: Icons.translate,
  SettingsPageRef.motion: Icons.animation,
  SettingsPageRef.browse: Icons.image_outlined,
  SettingsPageRef.navigation: Icons.dashboard_customize_outlined,
  SettingsPageRef.muted: Icons.block_outlined,
  SettingsPageRef.network: Icons.network_check,
  SettingsPageRef.download: Icons.download_outlined,
  SettingsPageRef.backup: Icons.backup_outlined,
  SettingsPageRef.about: Icons.info_outline,
  SettingsPageRef.frameProbe: Icons.monitor_heart_outlined,
};

/// The search field under the title: the field plus its bottom padding.
const double _searchBarExtent = 48 + FuncSpacing.sm;

class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.query, this.onSelectLocation});

  final String query;
  final ValueChanged<String>? onSelectLocation;

  @override
  Widget build(BuildContext context) {
    final results = searchSettings(context.l10n, query);
    if (results.isEmpty) {
      return FeedEmpty(
        icon: Icons.search_off,
        title: context.l10n.settingsSearchEmpty,
      );
    }
    return settingsNarrowBody(
      SmoothWheelScroll(
        builder: (context, controller, physics) => ListView(
          controller: controller,
          physics: physics,
          // The results are a lookup: dragging them puts the keyboard away.
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.only(
            top: FuncSpacing.sm,
            bottom: FuncSpacing.xl,
          ),
          children: [
            SettingsGroup(
              children: [
                for (final result in results)
                  SettingsTile(
                    title: result.label,
                    subtitle: result.path.isEmpty
                        ? null
                        : Text(result.path.join(' › ')),
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
          ],
        ),
      ),
    );
  }
}

class _SettingsGroups extends ConsumerWidget {
  const _SettingsGroups({
    required this.settings,
    this.selectedPage,
    this.onSelectLocation,
  });

  final AppSettings settings;
  final SettingsPageRef? selectedPage;
  final ValueChanged<String>? onSelectLocation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return settingsNarrowBody(
      SmoothWheelScroll(
        builder: (context, controller, physics) => DeferredCacheListView(
          controller: controller,
          physics: physics,
          // A bounded ~15-tile list: prebuilding it, from the second frame,
          // keeps maxScrollExtent stable during a fling.
          scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
          padding: const EdgeInsets.only(
            top: FuncSpacing.sm,
            bottom: FuncSpacing.xl,
          ),
          children: [
            ..._indexGroups(
              context,
              ref,
              settings,
              selectedPage: selectedPage,
              onSelectLocation: onSelectLocation,
            ),
            _DeveloperSettingsGroup(
              selected: selectedPage == SettingsPageRef.frameProbe,
              onSelectLocation: onSelectLocation,
            ),
          ],
        ),
      ),
    );
  }
}

Widget _wrapSelectedTile(
  BuildContext context, {
  required bool selected,
  required Widget child,
}) {
  if (!selected) return child;
  final scheme = Theme.of(context).colorScheme;
  return ListTileTheme.merge(
    tileColor: scheme.secondaryContainer.withValues(alpha: 0.55),
    textColor: scheme.onSecondaryContainer,
    iconColor: scheme.onSecondaryContainer,
    child: child,
  );
}

/// The settings pages grouped by intent, as the index lists them, each
/// row with its summary. A group's circles share one category hue, a
/// different one per neighbouring group; account and about are neutral.
/// Destructive/transfer actions (backup) sit in their own "data" group.
List<Widget> _indexGroups(
  BuildContext context,
  WidgetRef ref,
  AppSettings settings, {
  SettingsPageRef? selectedPage,
  ValueChanged<String>? onSelectLocation,
}) {
  final l10n = context.l10n;
  final scheme = Theme.of(context).colorScheme;
  final neutral = neutralCategoryTone(scheme);
  CategoryTone hue(double hue) => categoryTone(scheme, hue);
  final groups =
      <({String? title, CategoryTone tone, List<SettingsPageRef> pages})>[
        (
          title: l10n.accountSettings,
          tone: neutral,
          pages: const [SettingsPageRef.account],
        ),
        (
          title: l10n.settingsGroupAppearance,
          tone: hue(CategoryHue.purple),
          pages: const [
            SettingsPageRef.theme,
            SettingsPageRef.language,
            SettingsPageRef.translate,
            SettingsPageRef.motion,
          ],
        ),
        (
          title: l10n.settingsGroupBrowse,
          tone: hue(CategoryHue.blue),
          pages: const [
            SettingsPageRef.browse,
            SettingsPageRef.navigation,
            SettingsPageRef.muted,
          ],
        ),
        (
          title: l10n.settingsGroupNetwork,
          tone: hue(CategoryHue.green),
          pages: const [SettingsPageRef.network, SettingsPageRef.download],
        ),
        (
          title: l10n.settingsGroupData,
          tone: hue(CategoryHue.orange),
          pages: const [SettingsPageRef.backup],
        ),
        (title: null, tone: neutral, pages: const [SettingsPageRef.about]),
      ];
  return [
    for (final group in groups)
      SettingsGroup(
        title: group.title == null ? null : Text(group.title!),
        children: [
          for (final page in group.pages)
            _wrapSelectedTile(
              context,
              selected: selectedPage == page,
              child: SettingsTile.topLevel(
                setting: page,
                icon: settingsPageIcons[page],
                subtitle: _pageSummary(context, ref, settings, page),
                tone: group.tone,
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
        '${namingPresetLabel(context, settings.namingRule.preset)} · '
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
    this.onSelectLocation,
  });

  final bool selected;
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
        _wrapSelectedTile(
          context,
          selected: selected,
          child: SettingsTile.topLevel(
            setting: probe,
            icon: settingsPageIcons[probe],
            tone: neutralCategoryTone(Theme.of(context).colorScheme),
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
class _VersionSummary extends StatelessWidget {
  const _VersionSummary();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Text(info?.version ?? '—');
      },
    );
  }
}
