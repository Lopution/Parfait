import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/routes.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/settings/settings_section.dart';
import '../../app/widgets/settings/settings_tile.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/account_transfer.dart';
import '../../core/auth/account_transfer_service.dart';
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
      appBar: AppBar(title: Text(context.l10n.settingsTitle)),
      body: settings.when(
        loading: () => const FeedLoading(),
        error: (error, _) => SettingsLoadError(
          error: error,
          onRetry: () => ref.read(settingsProvider.notifier).reload(),
        ),
        data: (_) => _SettingsList(accounts: accounts),
      ),
    );
  }
}

class _SettingsList extends ConsumerWidget {
  const _SettingsList({required this.accounts});

  final AsyncValue<AccountState> accounts;

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
    // Shaft-style hub: tiles are grouped by intent under labeled section
    // headers instead of a flat list with bare dividers. Destructive/
    // transfer actions (backup) sit in their own "data" group.
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        AccountCard(
          account: account,
          onLongPress: account == null
              ? null
              : () => _copyAccount(context, ref),
        ),
        SettingsTile(
          icon: Icons.manage_accounts_outlined,
          title: context.l10n.accountSettings,
          onTap: () => openSettingsPage(context, '/settings/account'),
        ),
        SettingsSection(title: Text(context.l10n.settingsGroupAppearance)),
        SettingsTile(
          icon: Icons.palette_outlined,
          title: context.l10n.themeSettings,
          onTap: () => openSettingsPage(context, '/settings/theme'),
        ),
        SettingsTile(
          icon: Icons.language,
          title: context.l10n.languageSettings,
          onTap: () => openSettingsPage(context, '/settings/language'),
        ),
        SettingsTile(
          icon: Icons.translate,
          title: context.l10n.translateSettings,
          onTap: () => openSettingsPage(context, '/settings/translate'),
        ),
        SettingsSection(title: Text(context.l10n.settingsGroupBrowse)),
        SettingsTile(
          icon: Icons.image_outlined,
          title: context.l10n.browseSettings,
          onTap: () => openSettingsPage(context, '/settings/browse'),
        ),
        SettingsTile(
          icon: Icons.block_outlined,
          title: context.l10n.mutedItemsSettings,
          onTap: () => openSettingsPage(context, '/settings/muted'),
        ),
        SettingsTile(
          icon: Icons.history,
          title: context.l10n.historySettings,
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
        SettingsSection(title: Text(context.l10n.settingsGroupNetwork)),
        SettingsTile(
          icon: Icons.network_check,
          title: context.l10n.networkSettings,
          onTap: () => openSettingsPage(context, '/settings/network'),
        ),
        SettingsTile(
          icon: Icons.download_outlined,
          title: context.l10n.downloadSettings,
          onTap: () => openSettingsPage(context, '/settings/download'),
        ),
        SettingsTile(
          icon: Icons.downloading_outlined,
          title: context.l10n.downloaderSettings,
          onTap: () => openSettingsPage(context, '/settings/tasks'),
        ),
        SettingsSection(title: Text(context.l10n.settingsGroupData)),
        SettingsTile(
          icon: Icons.backup_outlined,
          title: context.l10n.backupSettings,
          onTap: () => openSettingsPage(context, '/settings/backup'),
        ),
        const Divider(),
        SettingsTile(
          icon: Icons.info_outline,
          title: context.l10n.aboutSettings,
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
    );
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
