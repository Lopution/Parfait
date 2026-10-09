import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../app/widgets/app_top_bar.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/settings/settings_group.dart';
import '../../app/widgets/settings/settings_tile.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/auth/account_store.dart';
import '../../core/comments/comment_translation.dart';
import '../../core/debug/frame_probe.dart';
import '../../core/mute/mute_store.dart';
import '../../core/navigation/route_observer.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/settings/shared_preferences.dart';
import '../../l10n/context.dart';
import 'settings_catalog.dart';
import 'settings_helpers.dart';

export 'pages/about_settings_page.dart';
export 'pages/account_settings_page.dart';
export 'pages/backup_settings_page.dart';
export 'pages/muted_items_page.dart';
export 'pages/browse_settings_page.dart';
export 'pages/download_settings_page.dart';
export 'pages/download_destination_page.dart';
export 'pages/download_tasks_page.dart';
export 'pages/language_settings_page.dart';
export 'pages/motion_settings_page.dart';
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
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final query = _query.text;
    return Scaffold(
      appBar: AppTopBar(
        title: Text(context.l10n.settingsTitle),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(_searchBarExtent),
          child: settingsNarrowBody(
            Padding(
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
            ),
          ),
        ),
      ),
      body: settings.when(
        loading: () => const FeedLoading(),
        error: (error, _) => SettingsLoadError(
          error: error,
          onRetry: () => ref.read(settingsProvider.notifier).reload(),
        ),
        data: (settings) => query.trim().isEmpty
            ? _SettingsGroups(settings: settings)
            : _SearchResults(query: query),
      ),
    );
  }
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
  const _SearchResults({required this.query});

  final String query;

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
      ListView(
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
                  onTap: () => openSettingsPage(context, result.location),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsGroups extends ConsumerWidget {
  const _SettingsGroups({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountStoreProvider).value?.current;
    // Root summaries answer "what is the current value" (Android summary
    // convention): concrete values, never a description of the title.
    final muted = ref.watch(muteStoreProvider);
    final mutedCount =
        muted.tags.length + muted.users.length + muted.works.length;
    SettingsTile page(SettingsPageRef page, {Widget? subtitle}) => SettingsTile(
      setting: page,
      icon: settingsPageIcons[page],
      subtitle: subtitle,
      onTap: () => openSettingsPage(context, page.path),
    );

    // Tiles are grouped by intent under labeled section headers.
    // Destructive/transfer actions (backup) sit in their own "data" group.
    return settingsNarrowBody(
      ListView(
        // A bounded ~15-tile list: prebuilding it keeps maxScrollExtent
        // stable during a fling.
        scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
        padding: const EdgeInsets.only(
          top: FuncSpacing.sm,
          bottom: FuncSpacing.xl,
        ),
        children: [
          SettingsGroup(
            title: Text(context.l10n.accountSettings),
            children: [
              page(
                SettingsPageRef.account,
                subtitle: Text(account?.name ?? context.l10n.signedOut),
              ),
            ],
          ),
          SettingsGroup(
            title: Text(context.l10n.settingsGroupAppearance),
            children: [
              page(
                SettingsPageRef.theme,
                subtitle: Text(themeModeLabel(context, settings.themeCode)),
              ),
              page(
                SettingsPageRef.language,
                subtitle: Text(languageDisplayName(settings.languageTag)),
              ),
              page(
                SettingsPageRef.translate,
                subtitle: _TranslationSummary(
                  provider: settings.translationProvider,
                ),
              ),
              page(
                SettingsPageRef.motion,
                subtitle: Text(
                  settings.reduceMotion
                      ? context.l10n.reduceMotion
                      : animationSpeedLabel(context, settings.animationSpeed),
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: Text(context.l10n.settingsGroupBrowse),
            children: [
              // No single value summarizes the page now that the image
              // source lives in network settings — a static hint instead,
              // same as the backup tile.
              page(
                SettingsPageRef.browse,
                subtitle: Text(context.l10n.settingsBrowseHint),
              ),
              page(
                SettingsPageRef.muted,
                subtitle: Text(
                  mutedCount == 0
                      ? context.l10n.mutedEmpty
                      : context.l10n.settingsMutedSummary(mutedCount),
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: Text(context.l10n.settingsGroupNetwork),
            children: [
              page(
                SettingsPageRef.network,
                subtitle: Text(networkModeLabel(context, settings.networkMode)),
              ),
              page(
                SettingsPageRef.download,
                subtitle: Text(
                  '${namingPresetLabel(context, settings.namingRule.preset)} · '
                  '${downloadDestinationLabel(context, settings.downloadDestination)}',
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: Text(context.l10n.settingsGroupData),
            children: [
              // No natural current value exists for backup — the static hint
              // tells the user what the page does instead (per design §4.8-1).
              page(
                SettingsPageRef.backup,
                subtitle: Text(context.l10n.backupHint),
              ),
            ],
          ),
          SettingsGroup(
            children: [
              page(SettingsPageRef.about, subtitle: const _VersionSummary()),
            ],
          ),
          // Frame probe is a diagnostics tool, not a preference: it ships in
          // every build but stays hidden until the about-page gesture (or a
          // non-release build) unlocks the developer group. A
          // `PIXIV_FRAME_PROBE` dart-define shows it in release for signed
          // measurement packages; default release builds are unchanged.
          if (ref.watch(developerOptionsProvider) ||
              !kReleaseMode ||
              kPixivFrameProbe)
            SettingsGroup(
              title: Text(context.l10n.settingsGroupDeveloper),
              children: [page(SettingsPageRef.frameProbe)],
            ),
        ],
      ),
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
        return Text(
          '$label · '
          '${state ? context.l10n.settingsCredentialConfigured : context.l10n.settingsCredentialNotConfigured}',
        );
      },
    );
  }
}

/// Version string under the about entry, same source the about page uses —
/// the platform package metadata, not a literal.
class _VersionSummary extends StatelessWidget {
  const _VersionSummary();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Text(info == null ? '—' : '${info.version}+${info.buildNumber}');
      },
    );
  }
}
