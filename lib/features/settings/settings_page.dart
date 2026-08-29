import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pixiv_image.dart';
import '../../app/replica_page_route.dart';
import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/account_transfer.dart';
import '../../core/auth/account_transfer_service.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_providers.dart';
import '../../core/download/download_task.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/blocked_tags.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/updater/update_providers.dart';
import '../../core/updater/update_service.dart';
import '../login/login_page.dart';
import '../profile/profile_edit_page.dart' as profile_edit;
import '../profile/user_page.dart' as profile;
import '../history/history_page.dart';

String _settingsText(BuildContext context, String key) {
  return ReplicaStrings.fromTag(
    Localizations.localeOf(context).toLanguageTag(),
    key,
  );
}

Future<bool> _persistSettings(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
    return true;
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_settingsText(context, 'settingsWriteFailed')}: $error',
          ),
        ),
      );
    }
    return false;
  }
}

void _openSettingsPage(BuildContext context, Widget page) {
  Navigator.of(
    context,
  ).push<void>(ReplicaPageRoute<void>(builder: (_) => page));
}

/// beta56-compatible Settings information architecture.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final accounts = ref.watch(accountStoreProvider);
    return Scaffold(
      appBar: AppBar(title: Text(_settingsText(context, 'settingsTitle'))),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _SettingsLoadError(
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
    final account = accounts.value?.current;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _AccountCard(
          account: account,
          onLongPress: account == null
              ? null
              : () => _copyAccount(context, ref),
        ),
        const Divider(),
        _SettingsRouteTile(
          icon: Icons.manage_accounts_outlined,
          title: _settingsText(context, 'accountSettings'),
          onTap: () => _openSettingsPage(context, const AccountSettingsPage()),
        ),
        const Divider(),
        _SettingsRouteTile(
          icon: Icons.palette_outlined,
          title: _settingsText(context, 'themeSettings'),
          onTap: () => _openSettingsPage(context, const ThemeSettingsPage()),
        ),
        _SettingsRouteTile(
          icon: Icons.language,
          title: _settingsText(context, 'languageSettings'),
          onTap: () => _openSettingsPage(context, const LanguageSettingsPage()),
        ),
        _SettingsRouteTile(
          icon: Icons.translate,
          title: _settingsText(context, 'translateSettings'),
          onTap: () =>
              _openSettingsPage(context, const TranslateSettingsPage()),
        ),
        const Divider(),
        _SettingsRouteTile(
          icon: Icons.image_outlined,
          title: _settingsText(context, 'browseSettings'),
          onTap: () => _openSettingsPage(context, const BrowseSettingsPage()),
        ),
        _SettingsRouteTile(
          icon: Icons.download_outlined,
          title: _settingsText(context, 'downloadSettings'),
          onTap: () => _openSettingsPage(context, const DownloadSettingsPage()),
        ),
        _SettingsRouteTile(
          icon: Icons.history,
          title: _settingsText(context, 'historySettings'),
          onTap: () => _openSettingsPage(context, const HistorySettingsPage()),
        ),
        _SettingsRouteTile(
          icon: Icons.block_outlined,
          title: _settingsText(context, 'blockTagSettings'),
          onTap: () => _openSettingsPage(context, const BlockedTagsPage()),
        ),
        const Divider(),
        _SettingsRouteTile(
          icon: Icons.downloading_outlined,
          title: _settingsText(context, 'downloaderSettings'),
          onTap: () => _openSettingsPage(context, const DownloadTasksPage()),
        ),
        const Divider(),
        _SettingsRouteTile(
          icon: Icons.info_outline,
          title: _settingsText(context, 'aboutSettings'),
          onTap: () => _openSettingsPage(context, const AboutSettingsPage()),
        ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_settingsText(context, 'accountTransferCopied')),
          ),
        );
      } on AccountTransferException catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_transferErrorText(context, error.code))),
        );
      }
    }());
  }
}

class _SettingsRouteTile extends StatelessWidget {
  const _SettingsRouteTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, this.onLongPress});

  final Account? account;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final value = account;
    return Card(
      margin: const EdgeInsets.all(12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: _AccountAvatar(account: value),
        title: Text(
          value?.name ?? _settingsText(context, 'signedOut'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          value == null
              ? _settingsText(context, 'accountProfile')
              : value.mailAddress ??
                    '${_settingsText(context, 'accountId')}: ${value.id}',
        ),
        trailing: value == null ? null : const Icon(Icons.chevron_right),
        onTap: value == null
            ? null
            : () => _openSettingsPage(
                context,
                profile.MePage(
                  onEditProfile: () => _openSettingsPage(
                    context,
                    profile_edit.ProfileEditPage(userId: value.userId),
                  ),
                ),
              ),
        onLongPress: onLongPress,
      ),
    );
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
  return _settingsText(context, key);
}

class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({required this.account});

  final Account? account;

  @override
  Widget build(BuildContext context) {
    final url = account?.profileImageUrl;
    if (url == null || url.isEmpty) {
      return const CircleAvatar(child: Icon(Icons.person_outline));
    }
    return ClipOval(
      child: SizedBox(
        width: 58,
        height: 58,
        child: PixivImage(url: url, fit: BoxFit.cover),
      ),
    );
  }
}

class _SettingsLoadError extends StatelessWidget {
  const _SettingsLoadError({required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.settings_outlined, size: 48),
            const SizedBox(height: 12),
            Text(_settingsText(context, 'settingsReadFailed')),
            const SizedBox(height: 8),
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onRetry,
              child: Text(_settingsText(context, 'retry')),
            ),
          ],
        ),
      ),
    );
  }
}

/// Read-only local account profile entry. It is deliberately backed by the
/// account store; the later profile task owns remote profile editing.
class MePage extends ConsumerWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountStoreProvider).value?.current;
    return Scaffold(
      appBar: AppBar(title: Text(_settingsText(context, 'accountProfile'))),
      body: account == null
          ? Center(child: Text(_settingsText(context, 'noAccounts')))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(child: _AccountAvatar(account: account)),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    account.name,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (account.mailAddress != null)
                  Center(child: Text(account.mailAddress!)),
                const SizedBox(height: 24),
                ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: Text(_settingsText(context, 'accountId')),
                  trailing: Text(account.id),
                ),
                if (account.authState == AccountAuthState.reauthRequired)
                  ListTile(
                    leading: const Icon(Icons.warning_amber_outlined),
                    title: Text(_settingsText(context, 'reauthRequired')),
                  ),
                const Divider(),
                Text(
                  _settingsText(context, 'profileReadOnly'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () =>
                      _openSettingsPage(context, const AccountSettingsPage()),
                  child: Text(_settingsText(context, 'accountManagement')),
                ),
              ],
            ),
    );
  }
}

class AccountSettingsPage extends ConsumerWidget {
  const AccountSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountStoreProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_settingsText(context, 'accountManagement')),
        actions: [
          IconButton(
            tooltip: _settingsText(context, 'addAccount'),
            icon: const Icon(Icons.add),
            onPressed: () => _openSettingsPage(context, const LoginPage()),
          ),
        ],
      ),
      body: accounts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (state) => state.accounts.isEmpty
            ? Center(child: Text(_settingsText(context, 'noAccounts')))
            : ListView.builder(
                itemCount: state.accounts.length,
                itemBuilder: (context, index) {
                  final account = state.accounts[index];
                  final selected = state.currentId == account.id;
                  return ListTile(
                    leading: _AccountAvatar(account: account),
                    title: Text(account.name),
                    subtitle: Text(
                      account.mailAddress ??
                          '${_settingsText(context, 'accountId')}: ${account.id}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (selected)
                          Icon(
                            Icons.check,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        IconButton(
                          tooltip: _settingsText(context, 'removeAccount'),
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () =>
                              _confirmRemove(context, ref, account),
                        ),
                      ],
                    ),
                    onTap: selected
                        ? null
                        : () => _persistSettings(
                            context,
                            () => ref
                                .read(accountStoreProvider.notifier)
                                .switchAccount(account.id),
                          ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    Account account,
  ) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_settingsText(context, 'removeAccount')),
        content: Text(_settingsText(context, 'removeAccountConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_settingsText(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_settingsText(context, 'confirm')),
          ),
        ],
      ),
    );
    if (remove != true || !context.mounted) return;
    await _persistSettings(
      context,
      () => ref.read(accountStoreProvider.notifier).removeAccount(account.id),
    );
  }
}

class ThemeSettingsPage extends ConsumerWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value;
    if (settings == null) return const _SettingsProgress();
    final items = [
      (AppSettings.darkTheme, _settingsText(context, 'dark')),
      (AppSettings.lightTheme, _settingsText(context, 'light')),
      (AppSettings.systemTheme, _settingsText(context, 'system')),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(_settingsText(context, 'themeSettings'))),
      body: ListView(
        children: [
          for (final item in items)
            ListTile(
              title: Text(item.$2),
              trailing: settings.themeCode == item.$1
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => _persistSettings(
                context,
                () => ref.read(settingsProvider.notifier).selectTheme(item.$1),
              ),
            ),
        ],
      ),
    );
  }
}

class LanguageSettingsPage extends ConsumerWidget {
  const LanguageSettingsPage({super.key});

  static const _items = [
    ('简体中文', 'zh-CN'),
    ('English', 'en-US'),
    ('日本語', 'ja-JP'),
    ('Русский', 'ru-RU'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value;
    if (settings == null) return const _SettingsProgress();
    return Scaffold(
      appBar: AppBar(title: Text(_settingsText(context, 'languageSettings'))),
      body: ListView(
        children: [
          for (final item in _items)
            ListTile(
              title: Text(item.$1),
              trailing: settings.languageTag == item.$2
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => _persistSettings(
                context,
                () =>
                    ref.read(settingsProvider.notifier).selectLanguage(item.$2),
              ),
            ),
        ],
      ),
    );
  }
}

class TranslateSettingsPage extends ConsumerWidget {
  const TranslateSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value;
    if (settings == null) return const _SettingsProgress();
    final items = [
      (TranslationProvider.google, _settingsText(context, 'translateGoogle')),
      (
        TranslationProvider.disabled,
        _settingsText(context, 'translateDisabled'),
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(_settingsText(context, 'translateSettings'))),
      body: ListView(
        children: [
          for (final item in items)
            ListTile(
              title: Text(item.$2),
              trailing: settings.translationProvider == item.$1
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => _persistSettings(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .selectTranslationProvider(item.$1),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _settingsText(context, 'translateCredentialHint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class BrowseSettingsPage extends ConsumerWidget {
  const BrowseSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value;
    if (settings == null) return const _SettingsProgress();
    final sources = [
      (
        AppSettings.normalImageSource,
        _settingsText(context, 'imageSourceNormal'),
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(_settingsText(context, 'browseSettings'))),
      body: ListView(
        children: [
          _SectionLabel(label: _settingsText(context, 'imageSource')),
          for (final source in sources)
            ListTile(
              title: Text(source.$2),
              trailing: settings.imageSource == source.$1
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => _persistSettings(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .selectImageSource(source.$1),
              ),
            ),
          const Divider(),
          SwitchListTile(
            title: Text(_settingsText(context, 'previewQuality')),
            value: settings.previewQuality,
            onChanged: (value) => _persistSettings(
              context,
              () =>
                  ref.read(settingsProvider.notifier).setPreviewQuality(value),
            ),
          ),
          SwitchListTile(
            title: Text(_settingsText(context, 'scaleQuality')),
            value: settings.scaleQuality,
            onChanged: (value) => _persistSettings(
              context,
              () => ref.read(settingsProvider.notifier).setScaleQuality(value),
            ),
          ),
          const Divider(),
          SwitchListTile(
            title: Text(_settingsText(context, 'pixivHistory')),
            value: settings.enablePixivHistory,
            onChanged: (value) => _persistSettings(
              context,
              () => ref
                  .read(settingsProvider.notifier)
                  .setPixivHistoryEnabled(value),
            ),
          ),
          SwitchListTile(
            title: Text(_settingsText(context, 'blockR18')),
            value: settings.enableLocalBlockR18,
            onChanged: (value) => _persistSettings(
              context,
              () => ref.read(settingsProvider.notifier).setLocalBlockR18(value),
            ),
          ),
          SwitchListTile(
            title: Text(_settingsText(context, 'blockAI')),
            value: settings.enableLocalBlockAI,
            onChanged: (value) => _persistSettings(
              context,
              () => ref.read(settingsProvider.notifier).setLocalBlockAI(value),
            ),
          ),
        ],
      ),
    );
  }
}

class DownloadSettingsPage extends ConsumerStatefulWidget {
  const DownloadSettingsPage({super.key});

  @override
  ConsumerState<DownloadSettingsPage> createState() =>
      _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends ConsumerState<DownloadSettingsPage> {
  late final TextEditingController _namingController;
  late final FocusNode _namingFocusNode;
  int? _draftMaxDownloads;

  @override
  void initState() {
    super.initState();
    _namingController = TextEditingController();
    _namingFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _namingController.dispose();
    _namingFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value;
    if (settings == null) return const _SettingsProgress();
    _draftMaxDownloads ??= settings.maxDownloadCount;
    if (!_namingFocusNode.hasFocus &&
        _namingController.text != (settings.namingRule ?? '')) {
      _namingController.text = settings.namingRule ?? '';
    }
    return Scaffold(
      appBar: AppBar(title: Text(_settingsText(context, 'downloadSettings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${_settingsText(context, 'maxDownloadCount')}: $_draftMaxDownloads',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Slider(
            min: 1,
            max: 10,
            divisions: 9,
            value: (_draftMaxDownloads ?? settings.maxDownloadCount).toDouble(),
            label: '$_draftMaxDownloads',
            onChanged: (value) =>
                setState(() => _draftMaxDownloads = value.round()),
            onChangeEnd: (value) => _persistSettings(
              context,
              () => ref
                  .read(settingsProvider.notifier)
                  .setMaxDownloadCount(value.round()),
            ),
          ),
          const Divider(),
          TextField(
            controller: _namingController,
            focusNode: _namingFocusNode,
            decoration: InputDecoration(
              labelText: _settingsText(context, 'namingRule'),
              hintText: _settingsText(context, 'namingRuleHint'),
            ),
            maxLength: 128,
          ),
          FilledButton(
            onPressed: () async {
              final saved = await _persistSettings(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .setNamingRule(
                      _namingController.text.trim().isEmpty
                          ? null
                          : _namingController.text.trim(),
                    ),
              );
              if (saved && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(_settingsText(context, 'saved'))),
                );
              }
            },
            child: Text(_settingsText(context, 'saved')),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_settingsText(context, 'saveFolder')),
            trailing: Text(
              settings.saveFolder ?? _settingsText(context, 'notConfigured'),
            ),
          ),
        ],
      ),
    );
  }
}

class HistorySettingsPage extends ConsumerWidget {
  const HistorySettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value;
    if (settings == null) return const _SettingsProgress();
    return Scaffold(
      appBar: AppBar(title: Text(_settingsText(context, 'historySettings'))),
      body: ListView(
        children: [
          SwitchListTile(
            title: Text(_settingsText(context, 'localHistory')),
            value: settings.enableHistory,
            onChanged: (value) => _persistSettings(
              context,
              () =>
                  ref.read(settingsProvider.notifier).setHistoryEnabled(value),
            ),
          ),
          SwitchListTile(
            title: Text(_settingsText(context, 'pixivHistory')),
            value: settings.enablePixivHistory,
            onChanged: (value) => _persistSettings(
              context,
              () => ref
                  .read(settingsProvider.notifier)
                  .setPixivHistoryEnabled(value),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.history_outlined),
            title: Text(_settingsText(context, 'historyView')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showHistoryPage(context),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _settingsText(context, 'historySettingsHint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class BlockedTagsPage extends ConsumerStatefulWidget {
  const BlockedTagsPage({super.key});

  @override
  ConsumerState<BlockedTagsPage> createState() => _BlockedTagsPageState();
}

class _BlockedTagsPageState extends ConsumerState<BlockedTagsPage> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _addTag(String value) async {
    final tag = value.trim();
    if (tag.isEmpty) return;
    final tags = ref.read(blockedTagsProvider);
    if (!tags.contains(tag)) {
      try {
        await ref.read(blockedTagsProvider.notifier).toggle(tag);
        _controller.clear();
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tags = ref.watch(blockedTagsProvider).toList()..sort();
    return Scaffold(
      appBar: AppBar(title: Text(_settingsText(context, 'blockTagSettings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: _settingsText(context, 'blockTagInputHint'),
              suffixIcon: IconButton(
                tooltip: _settingsText(context, 'addAccount'),
                icon: const Icon(Icons.add),
                onPressed: () => _addTag(_controller.text),
              ),
            ),
            onSubmitted: _addTag,
          ),
          const SizedBox(height: 12),
          if (tags.isEmpty)
            Center(child: Text(_settingsText(context, 'noBlockedTags')))
          else
            for (final tag in tags)
              ListTile(
                title: Text(tag),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () =>
                      ref.read(blockedTagsProvider.notifier).toggle(tag),
                ),
              ),
        ],
      ),
    );
  }
}

class DownloadTasksPage extends ConsumerStatefulWidget {
  const DownloadTasksPage({super.key});

  @override
  ConsumerState<DownloadTasksPage> createState() => _DownloadTasksPageState();
}

class _DownloadTasksPageState extends ConsumerState<DownloadTasksPage> {
  late final DownloadManager _manager;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _manager = ref.read(downloadManagerProvider);
    _changes = _manager.changes.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(
      _manager.recover().whenComplete(() {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _manager.tasks;
    return Scaffold(
      appBar: AppBar(title: Text(_settingsText(context, 'downloaderSettings'))),
      body: tasks.isEmpty
          ? Center(child: Text(_settingsText(context, 'downloadTasksEmpty')))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_settingsText(context, 'downloaderSettingsHint')),
                ),
                for (final task in tasks)
                  _DownloadTaskTile(task: task, manager: _manager),
              ],
            ),
    );
  }
}

class _DownloadTaskTile extends StatelessWidget {
  const _DownloadTaskTile({required this.task, required this.manager});

  final DownloadTaskSnapshot task;
  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final progress = task.progress;
    final canCancel =
        task.status == DownloadStatus.queued ||
        task.status == DownloadStatus.running ||
        task.status == DownloadStatus.canceling;
    final canRetry =
        task.status == DownloadStatus.failed ||
        task.status == DownloadStatus.canceled ||
        task.status == DownloadStatus.retryable;
    return Card(
      child: ListTile(
        title: Text(task.displayName, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_downloadStatusText(context, task.status)),
            LinearProgressIndicator(value: progress),
            if (task.error != null) Text(task.error!),
          ],
        ),
        trailing: canCancel
            ? IconButton(
                tooltip: _settingsText(context, 'cancelDownload'),
                icon: const Icon(Icons.close),
                onPressed: () => manager.cancel(task.id),
              )
            : canRetry
            ? IconButton(
                tooltip: _settingsText(context, 'retryDownload'),
                icon: const Icon(Icons.refresh),
                onPressed: () => manager.retry(task.id),
              )
            : Icon(
                task.status == DownloadStatus.succeeded
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
              ),
      ),
    );
  }

  String _downloadStatusText(BuildContext context, DownloadStatus status) {
    return switch (status) {
      DownloadStatus.queued => _settingsText(context, 'downloadQueued'),
      DownloadStatus.running => _settingsText(context, 'downloadRunning'),
      DownloadStatus.finalizing => _settingsText(context, 'downloadRunning'),
      DownloadStatus.canceling => _settingsText(context, 'downloadCanceling'),
      DownloadStatus.succeeded => _settingsText(context, 'downloadSucceeded'),
      DownloadStatus.failed => _settingsText(context, 'downloadFailed'),
      DownloadStatus.canceled => _settingsText(context, 'downloadCanceled'),
      DownloadStatus.retryable => _settingsText(context, 'downloadFailed'),
      DownloadStatus.orphaned => _settingsText(context, 'downloadFailed'),
    };
  }
}

class AboutSettingsPage extends ConsumerWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appName = 'Pixiv Func';
    final updateService = ref.watch(updateServiceProvider);
    return Scaffold(
      appBar: AppBar(title: Text(_settingsText(context, 'aboutSettings'))),
      body: ListView(
        children: [
          const ListTile(
            leading: Icon(Icons.apps),
            title: Text('Pixiv Func'),
            subtitle: Text('0.1.0+1'),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(_settingsText(context, 'aboutVersion')),
            trailing: const Text('0.1.0+1'),
          ),
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: Text(_settingsText(context, 'aboutLicense')),
            subtitle: Text(_settingsText(context, 'aboutLicenseText')),
            onTap: () => showLicensePage(
              context: context,
              applicationName: appName,
              applicationVersion: '0.1.0+1',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: Text(_settingsText(context, 'aboutAttribution')),
            subtitle: Text(_settingsText(context, 'aboutAttributionText')),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(_settingsText(context, 'aboutSource')),
            subtitle: const Text('github.com/Lopution/Pixiv-func'),
          ),
          const Divider(),
          updateService.when(
            loading: () => ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: Text(_settingsText(context, 'aboutCheckUpdate')),
              subtitle: Text(_settingsText(context, 'aboutCheckingUpdate')),
            ),
            error: (_, _) => ListTile(
              leading: const Icon(Icons.warning_amber_outlined),
              title: Text(_settingsText(context, 'aboutCheckUpdate')),
              subtitle: Text(_settingsText(context, 'aboutUpdateUnavailable')),
            ),
            data: (service) => _AboutUpdateSection(service: service),
          ),
        ],
      ),
    );
  }
}

class _AboutUpdateSection extends StatefulWidget {
  const _AboutUpdateSection({required this.service});

  final UpdateService service;

  @override
  State<_AboutUpdateSection> createState() => _AboutUpdateSectionState();
}

class _AboutUpdateSectionState extends State<_AboutUpdateSection> {
  late Future<UpdateCapability> _capability;
  UpdateCheckResult? _checkResult;
  UpdateApplyResult? _applyResult;
  var _checking = false;
  var _applying = false;

  @override
  void initState() {
    super.initState();
    _capability = widget.service.capability();
  }

  @override
  void didUpdateWidget(covariant _AboutUpdateSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      _capability = widget.service.capability();
      _checkResult = null;
      _applyResult = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<UpdateCapability>(
      future: _capability,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: Text(_settingsText(context, 'aboutCheckUpdate')),
            subtitle: Text(_settingsText(context, 'aboutCheckingUpdate')),
          );
        }
        final capability = snapshot.data;
        if (snapshot.hasError || capability == null) {
          return ListTile(
            leading: const Icon(Icons.warning_amber_outlined),
            title: Text(_settingsText(context, 'aboutCheckUpdate')),
            subtitle: Text(_settingsText(context, 'aboutUpdateUnavailable')),
          );
        }
        if (capability.storeManaged ||
            capability.flavor == UpdateFlavor.fdroid) {
          return ListTile(
            leading: const Icon(Icons.store_outlined),
            title: Text(_settingsText(context, 'aboutCheckUpdate')),
            subtitle: Text(_settingsText(context, 'aboutUpdateStore')),
          );
        }
        if (!capability.enabled) {
          return ListTile(
            leading: const Icon(Icons.warning_amber_outlined),
            title: Text(_settingsText(context, 'aboutCheckUpdate')),
            subtitle: Text(_settingsText(context, 'aboutUpdateUnavailable')),
          );
        }
        return _githubUpdateControls(context);
      },
    );
  }

  Widget _githubUpdateControls(BuildContext context) {
    final result = _checkResult;
    final release = result?.release;
    final statusText = switch (result?.status) {
      UpdateCheckStatus.available =>
        '${_settingsText(context, 'aboutUpdateAvailable')}: ${release!.manifest.version}',
      UpdateCheckStatus.disabled => _settingsText(
        context,
        'aboutUpdateUnavailable',
      ),
      UpdateCheckStatus.noUpdate => _settingsText(
        context,
        'aboutUpdateNoUpdate',
      ),
      UpdateCheckStatus.prerelease => _settingsText(
        context,
        'aboutUpdatePrerelease',
      ),
      UpdateCheckStatus.invalid ||
      UpdateCheckStatus.rateLimited ||
      UpdateCheckStatus.offline ||
      UpdateCheckStatus.failed ||
      UpdateCheckStatus.busy => _settingsText(context, 'aboutUpdateFailed'),
      null => null,
    };
    final applyText = switch (_applyResult?.status) {
      UpdateApplyStatus.installPermissionRequired => _settingsText(
        context,
        'aboutUpdatePermission',
      ),
      UpdateApplyStatus.installStarted => _settingsText(
        context,
        'aboutUpdateStarted',
      ),
      UpdateApplyStatus.failed ||
      UpdateApplyStatus.canceled => _settingsText(context, 'aboutUpdateFailed'),
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.system_update_outlined),
            title: Text(_settingsText(context, 'aboutCheckUpdate')),
            subtitle: Text(
              _checking || _applying
                  ? _settingsText(context, 'aboutUpdateDownloading')
                  : statusText ?? '',
            ),
          ),
          if (_checking || _applying) const LinearProgressIndicator(),
          if (applyText != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(applyText),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _checking
                ? null
                : _applying
                ? _cancelApply
                : release == null
                ? _check
                : () => _confirmAndApply(context, release),
            icon: Icon(
              _applying
                  ? Icons.close
                  : release == null
                  ? Icons.refresh
                  : Icons.download_outlined,
            ),
            label: Text(
              _applying
                  ? _settingsText(context, 'cancel')
                  : release == null
                  ? _settingsText(context, 'aboutCheckUpdate')
                  : _settingsText(context, 'aboutUpdateDownload'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _check() async {
    if (_checking || _applying) return;
    setState(() {
      _checking = true;
      _checkResult = null;
      _applyResult = null;
    });
    try {
      final result = await widget.service.check();
      if (mounted) setState(() => _checkResult = result);
    } on Object {
      if (mounted) {
        setState(
          () => _checkResult = const UpdateCheckResult(
            status: UpdateCheckStatus.failed,
            errorCode: 'check_failed',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _cancelApply() async {
    try {
      await widget.service.cancel();
    } on Object {
      if (mounted) {
        setState(
          () => _applyResult = const UpdateApplyResult(
            status: UpdateApplyStatus.failed,
            errorCode: 'cancel_failed',
          ),
        );
      }
    }
  }

  Future<void> _confirmAndApply(
    BuildContext context,
    UpdateRelease release,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_settingsText(context, 'aboutUpdateConfirmTitle')),
        content: Text(_settingsText(context, 'aboutUpdateConfirmDetail')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_settingsText(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_settingsText(context, 'confirm')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _applying = true;
      _applyResult = null;
    });
    try {
      final result = await widget.service.apply(release, confirmed: true);
      if (mounted) setState(() => _applyResult = result);
    } on Object {
      if (mounted) {
        setState(
          () => _applyResult = const UpdateApplyResult(
            status: UpdateApplyStatus.failed,
            errorCode: 'apply_failed',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }
}

class _SettingsProgress extends StatelessWidget {
  const _SettingsProgress();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
