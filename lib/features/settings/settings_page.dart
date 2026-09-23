import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../app/motion/app_overlays.dart';
import '../../app/navigation/routes.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/root_swipe_switcher.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/settings/settings_section.dart';
import '../../app/widgets/settings/settings_tile.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/account_transfer.dart';
import '../../core/auth/account_transfer_service.dart';
import '../../core/comments/comment_translation.dart';
import '../../core/download/download_providers.dart';
import '../../core/download/download_task.dart' show isTerminal;
import '../../core/mute/mute_store.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/settings/shared_preferences.dart';
import '../../l10n/context.dart';
import 'pages/account_settings_page.dart';
import 'settings_helpers.dart';

export 'pages/about_settings_page.dart';
export 'pages/account_settings_page.dart';
export 'pages/backup_settings_page.dart';
export 'pages/muted_items_page.dart';
export 'pages/browse_settings_page.dart';
export 'pages/download_settings_page.dart';
export 'pages/download_destination_page.dart';
export 'pages/download_tasks_page.dart';
export 'pages/history_settings_page.dart';
export 'pages/language_settings_page.dart';
export 'pages/theme_settings_page.dart';
export 'pages/translate_settings_page.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final accounts = ref.watch(accountStoreProvider);
    return Scaffold(
      // Root pages own no inline composer: leaving the default `true`
      // would subscribe this whole subtree to per-frame viewInsets churn
      // every time the IME animates (e.g. the push that hides the search
      // keyboard) — a relayout storm across all five live branches.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text(context.l10n.settingsTitle)),
      body: RootSwipeSwitcher(
        child: settings.when(
          loading: () => const FeedLoading(),
          error: (error, _) => SettingsLoadError(
            error: error,
            onRetry: () => ref.read(settingsProvider.notifier).reload(),
          ),
          data: (settings) =>
              _SettingsList(accounts: accounts, settings: settings),
        ),
      ),
    );
  }
}

class _SettingsList extends ConsumerWidget {
  const _SettingsList({required this.accounts, required this.settings});

  final AsyncValue<AccountState> accounts;
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (accounts.hasError) {
      return SettingsLoadError(
        error: accounts.error!,
        onRetry: () => ref.read(accountStoreProvider.notifier).reload(),
        messageKey: 'accountReadFailed',
      );
    }
    if (accounts.isLoading && !accounts.hasValue) {
      return const FeedLoading();
    }
    final state = accounts.value;
    if (state?.status == AccountStatus.failure) {
      return SettingsLoadError(
        error: state?.error ?? StateError('account state unavailable'),
        onRetry: () => ref.read(accountStoreProvider.notifier).reload(),
        messageKey: 'accountReadFailed',
      );
    }
    final account = state?.current;
    // Root summaries answer "what is the current value" (Android summary
    // convention): concrete values, never a description of the title.
    final muted = ref.watch(muteStoreProvider);
    final mutedCount =
        muted.tags.length + muted.users.length + muted.workIds.length;
    // One-time snapshot per design: the page does not subscribe to the
    // manager's `changes` stream, so this count refreshes with the next
    // page rebuild rather than live.
    final activeTasks = ref
        .read(downloadManagerProvider)
        .tasks
        .where((task) => !isTerminal(task.status))
        .length;
    final imageSource = switch (settings.imageSourceMode) {
      ImageSourceMode.auto =>
        ref.watch(autoImageSourceWinnerProvider) == null
            ? context.l10n.imageSourceAuto
            : context.l10n.imageSourceAutoWinner(
                ref.watch(autoImageSourceWinnerProvider)!,
              ),
      ImageSourceMode.custom =>
        settings.imageSource.isNotEmpty
            ? settings.imageSource
            : context.l10n.imageSourceCustomUnset,
      final mode => imageSourceLabel(context, mode),
    };
    // Shaft-style hub: tiles are grouped by intent under labeled section
    // headers instead of a flat list with bare dividers. Destructive/
    // transfer actions (backup) sit in their own "data" group.
    return settingsNarrowBody(
      ListView(
        // The root catalog is a bounded ~20-tile list: prebuilding all of
        // it keeps maxScrollExtent stable during a fling — a lazy extent
        // revision mid-flight makes the bottom-bar hide/show logic read
        // the spring-back as a real reverse scroll.
        scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          AccountCard(account: account),
          SettingsTile(
            icon: Icons.manage_accounts_outlined,
            title: context.l10n.accountSettings,
            subtitle: Text(account?.name ?? context.l10n.signedOut),
            onTap: () => openSettingsPage(context, '/settings/account'),
          ),
          // Credential export is a visible entry, not a hidden gesture: the
          // tile exists only for a signed-in account and the warning dialog
          // still gates the actual copy.
          if (account != null)
            SettingsTile(
              icon: Icons.send_to_mobile,
              title: context.l10n.accountTransferExportTitle,
              onTap: () => _confirmCopyAccount(context, ref),
            ),
          SettingsSection(title: Text(context.l10n.settingsGroupAppearance)),
          SettingsTile(
            icon: Icons.palette_outlined,
            title: context.l10n.themeSettings,
            subtitle: Text(themeModeLabel(context, settings.themeCode)),
            onTap: () => openSettingsPage(context, '/settings/theme'),
          ),
          SettingsTile(
            icon: Icons.language,
            title: context.l10n.languageSettings,
            subtitle: Text(languageDisplayName(settings.languageTag)),
            onTap: () => openSettingsPage(context, '/settings/language'),
          ),
          SettingsTile(
            icon: Icons.translate,
            title: context.l10n.translateSettings,
            subtitle: _TranslationSummary(
              provider: settings.translationProvider,
            ),
            onTap: () => openSettingsPage(context, '/settings/translate'),
          ),
          SettingsSection(title: Text(context.l10n.settingsGroupBrowse)),
          SettingsTile(
            icon: Icons.image_outlined,
            title: context.l10n.browseSettings,
            subtitle: Text(imageSource),
            onTap: () => openSettingsPage(context, '/settings/browse'),
          ),
          SettingsTile(
            icon: Icons.block_outlined,
            title: context.l10n.mutedItemsSettings,
            subtitle: Text(
              mutedCount == 0
                  ? context.l10n.mutedEmpty
                  : context.l10n.settingsMutedSummary(mutedCount),
            ),
            onTap: () => openSettingsPage(context, '/settings/muted'),
          ),
          // The history tile stays a configuration entry (D5): its summary
          // shows the switch states; the content view lives in the library
          // group below.
          SettingsTile(
            icon: Icons.manage_history,
            title: context.l10n.historySettings,
            subtitle: Text(
              context.l10n.settingsHistorySummary(
                settings.enableHistory
                    ? context.l10n.settingsSummaryOn
                    : context.l10n.settingsSummaryOff,
                settings.enablePixivHistory
                    ? context.l10n.settingsSummaryOn
                    : context.l10n.settingsSummaryOff,
              ),
            ),
            onTap: () => openSettingsPage(context, '/settings/history'),
          ),
          // Content destinations (not preferences) sit in their own group so
          // the preference sections stay unmixed — the split Shaft draws
          // between its drawer entries and the settings catalog.
          SettingsSection(title: Text(context.l10n.settingsGroupLibrary)),
          SettingsTile(
            icon: Icons.bookmark_border,
            title: context.l10n.watchLaterTitle,
            onTap: () => openWatchLater(context),
          ),
          SettingsTile(
            icon: Icons.collections_bookmark_outlined,
            title: context.l10n.watchlistTitle,
            onTap: () => openWatchlist(context),
          ),
          SettingsTile(
            icon: Icons.menu_book_outlined,
            title: context.l10n.localNovelsTitle,
            onTap: () => openLocalNovels(context),
          ),
          // D5: direct content entry — the history configuration tile above
          // keeps owning the switches; this one opens the content view.
          SettingsTile(
            icon: Icons.history,
            title: context.l10n.historyView,
            onTap: () => openHistory(context),
          ),
          SettingsSection(title: Text(context.l10n.settingsGroupNetwork)),
          SettingsTile(
            icon: Icons.network_check,
            title: context.l10n.networkSettings,
            subtitle: Text(networkModeLabel(context, settings.networkMode)),
            onTap: () => openSettingsPage(context, '/settings/network'),
          ),
          SettingsTile(
            icon: Icons.download_outlined,
            title: context.l10n.downloadSettings,
            subtitle: Text(
              '${namingPresetLabel(context, settings.namingRule.preset)} · '
              '${downloadDestinationLabel(context, settings.downloadDestination)}',
            ),
            onTap: () => openSettingsPage(context, '/settings/download'),
          ),
          SettingsTile(
            icon: Icons.downloading_outlined,
            title: context.l10n.downloaderSettings,
            subtitle: Text(
              context.l10n.settingsDownloadTasksSummary(activeTasks),
            ),
            onTap: () => openSettingsPage(context, '/settings/tasks'),
          ),
          SettingsSection(title: Text(context.l10n.settingsGroupData)),
          // No natural current value exists for backup — the static hint
          // tells the user what the page does instead (per design §4.8-1).
          SettingsTile(
            icon: Icons.backup_outlined,
            title: context.l10n.backupSettings,
            subtitle: Text(context.l10n.backupHint),
            onTap: () => openSettingsPage(context, '/settings/backup'),
          ),
          const Divider(),
          SettingsTile(
            icon: Icons.info_outline,
            title: context.l10n.aboutSettings,
            subtitle: const _VersionSummary(),
            onTap: () => openSettingsPage(context, '/settings/about'),
          ),
          // Frame probe is a diagnostics tool, not a preference: it ships in
          // every build but stays hidden until the about-page gesture (or a
          // non-release build) unlocks the developer group.
          if (ref.watch(developerOptionsProvider) || !kReleaseMode) ...[
            SettingsSection(title: Text(context.l10n.settingsGroupDeveloper)),
            SettingsTile(
              icon: Icons.monitor_heart_outlined,
              title: context.l10n.frameProbeTitle,
              onTap: () => openSettingsPage(context, '/settings/frame-probe'),
            ),
          ],
          const FuncNavBarSpacer(),
        ],
      ),
    );
  }

  /// Credential export is destructive-adjacent (plaintext tokens on the
  /// system clipboard): the entry is a visible tile, and this dialog carries
  /// the warning before any byte is copied.
  Future<void> _confirmCopyAccount(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.accountTransferExportTitle),
        content: Text(l10n.accountTransferWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      _copyAccount(context, ref);
    }
  }

  void _copyAccount(BuildContext context, WidgetRef ref) {
    unawaited(() async {
      try {
        await ref
            .read(accountTransferServiceProvider)
            .exportCurrentToClipboard();
        if (!context.mounted) return;
        showAppSnackBar(context, context.l10n.accountTransferCopied);
        // Android <13 cannot mark the clipboard entry as sensitive; the
        // credential sits in the system clipboard in plaintext. Never do
        // this silently (R4: 安全降级，不能静默少做一件事).
        final capabilities = await ref
            .read(transferClipboardProvider)
            .capabilities();
        if (!capabilities.sensitiveMarkSupported && context.mounted) {
          showAppSnackBar(
            context,
            context.l10n.accountTransferSensitiveWarning,
            duration: const Duration(seconds: 5),
          );
        }
      } on AccountTransferException catch (error) {
        if (!context.mounted) return;
        showAppSnackBar(context, _transferErrorText(context, error.code));
      }
    }());
  }
}

String _transferErrorText(BuildContext context, AccountTransferErrorCode code) {
  final key = switch (code) {
    AccountTransferErrorCode.corrupt => 'accountTransferCorrupt',
    AccountTransferErrorCode.credentialInvalid =>
      'accountTransferCredentialInvalid',
    AccountTransferErrorCode.verificationUnavailable =>
      'accountTransferVerificationUnavailable',
    AccountTransferErrorCode.noUsableAccount => 'accountTransferNoAccount',
    AccountTransferErrorCode.credentialUnavailable =>
      'accountTransferCredentialUnavailable',
    AccountTransferErrorCode.clipboardUnavailable =>
      'accountTransferClipboardUnavailable',
    AccountTransferErrorCode.storageFailure => 'accountTransferStorageFailure',
  };
  return settingsText(context, key);
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

class _TranslationSummaryState extends ConsumerState<_TranslationSummary> {
  Future<bool>? _configured;

  @override
  void initState() {
    super.initState();
    final store = ref.read(translationCredentialStoreProvider);
    _configured = switch (widget.provider) {
      TranslationProvider.baidu => store.hasBaidu(),
      TranslationProvider.translationLlm => store.hasLlm(),
      _ => null,
    };
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
