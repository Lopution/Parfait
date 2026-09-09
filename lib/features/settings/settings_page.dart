import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/person_avatar.dart';
import '../../app/motion/replica_page_route.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/account_transfer.dart';
import '../../core/auth/account_transfer_service.dart';
import '../../core/download/download_destination.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_providers.dart';
import '../../core/download/download_task.dart';
import '../../core/download/naming_rule.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/platform/saf_tree.dart';
import '../../core/comments/comment_translation.dart';
import '../../core/comments/translation_credentials.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/blocked_tags.dart';
import '../../core/settings/settings_controller.dart';
import '../../app/navigation/routes.dart';
import '../../core/updater/update_providers.dart';
import '../../core/updater/update_service.dart';
import '../profile/user_page.dart' as profile;
import '../../app/navigation/routes.dart' show openHistory, openLogin, openProfileEdit;
import 'network_settings_page.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/context.dart';

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
      showAppSnackBar(context, '${context.l10n.settingsWriteFailed}: $error',);
    }
    return false;
  }
}

Widget _settingsUnavailable(
  BuildContext context,
  WidgetRef ref,
  AsyncValue<AppSettings> state, {
  required String titleKey,
}) {
  return Scaffold(
    appBar: AppBar(title: Text(_settingsText(context, titleKey))),
    body: state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => SettingsLoadError(
        error: error,
        onRetry: () => ref.read(settingsProvider.notifier).reload(),
      ),
      // AsyncData<AppSettings> is never null; this branch only keeps the
      // helper total if the provider implementation changes later.
      data: (_) => const SizedBox.shrink(),
    ),
  );
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
      appBar: AppBar(title: Text(context.l10n.settingsTitle)),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
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
      return const Center(child: CircularProgressIndicator());
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
          title: context.l10n.accountSettings,
          onTap: () => _openSettingsPage(context, const AccountSettingsPage()),
        ),
        const Divider(),
        _SettingsRouteTile(
          icon: Icons.palette_outlined,
          title: context.l10n.themeSettings,
          onTap: () => _openSettingsPage(context, const ThemeSettingsPage()),
        ),
        _SettingsRouteTile(
          icon: Icons.language,
          title: context.l10n.languageSettings,
          onTap: () => _openSettingsPage(context, const LanguageSettingsPage()),
        ),
        _SettingsRouteTile(
          icon: Icons.translate,
          title: context.l10n.translateSettings,
          onTap: () =>
              _openSettingsPage(context, const TranslateSettingsPage()),
        ),
        const Divider(),
        _SettingsRouteTile(
          icon: Icons.network_check,
          title: context.l10n.networkSettings,
          onTap: () => _openSettingsPage(context, const NetworkSettingsPage()),
        ),
        _SettingsRouteTile(
          icon: Icons.image_outlined,
          title: context.l10n.browseSettings,
          onTap: () => _openSettingsPage(context, const BrowseSettingsPage()),
        ),
        _SettingsRouteTile(
          icon: Icons.download_outlined,
          title: context.l10n.downloadSettings,
          onTap: () => _openSettingsPage(context, const DownloadSettingsPage()),
        ),
        _SettingsRouteTile(
          icon: Icons.history,
          title: context.l10n.historySettings,
          onTap: () => _openSettingsPage(context, const HistorySettingsPage()),
        ),
        _SettingsRouteTile(
          icon: Icons.block_outlined,
          title: context.l10n.blockTagSettings,
          onTap: () => _openSettingsPage(context, const BlockedTagsPage()),
        ),
        const Divider(),
        _SettingsRouteTile(
          icon: Icons.downloading_outlined,
          title: context.l10n.downloaderSettings,
          onTap: () => _openSettingsPage(context, const DownloadTasksPage()),
        ),
        const Divider(),
        _SettingsRouteTile(
          icon: Icons.info_outline,
          title: context.l10n.aboutSettings,
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
        showAppSnackBar(context, context.l10n.accountTransferCopied);
        // Android <13 cannot mark the clipboard entry as sensitive; the
        // credential sits in the system clipboard in plaintext. Never do
        // this silently (R4: 安全降级，不能静默少做一件事).
        final capabilities = await ref
            .read(transferClipboardProvider)
            .capabilities();
        if (!capabilities.sensitiveMarkSupported && context.mounted) {
          showAppSnackBar(context, context.l10n.accountTransferSensitiveWarning, duration: const Duration(seconds: 5));
        }
      } on AccountTransferException catch (error) {
        if (!context.mounted) return;
        showAppSnackBar(context, _transferErrorText(context, error.code));
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
          value?.name ?? context.l10n.signedOut,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          value == null
              ? context.l10n.accountProfile
              : value.mailAddress ??
                    '${context.l10n.accountId}: ${value.id}',
        ),
        trailing: value == null ? null : const Icon(Icons.chevron_right),
        onTap: value == null
            ? null
            : () => _openSettingsPage(
                context,
                profile.MePage(
                  onEditProfile: () => openProfileEdit(context, value.userId),
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
    return SizedBox.square(
      dimension: 58,
      child: PersonAvatar(
        imageUrl: url == null || url.isEmpty ? null : url,
        radius: 29,
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
    final accounts = ref.watch(accountStoreProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.accountProfile)),
      body: accounts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => SettingsLoadError(
          error: error,
          onRetry: () => ref.read(accountStoreProvider.notifier).reload(),
          messageKey: 'accountReadFailed',
        ),
        data: (state) {
          if (state.status == AccountStatus.failure) {
            return SettingsLoadError(
              error: state.error ?? StateError('account state unavailable'),
              onRetry: () => ref.read(accountStoreProvider.notifier).reload(),
              messageKey: 'accountReadFailed',
            );
          }
          final account = state.current;
          return account == null
              ? Center(child: Text(context.l10n.noAccounts))
              : _buildAccountProfile(context, account);
        },
      ),
    );
  }

  Widget _buildAccountProfile(BuildContext context, Account account) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(child: _AccountAvatar(account: account)),
        const SizedBox(height: 16),
        Center(
          child: Text(
            account.name,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
          ),
        ),
        if (account.mailAddress != null)
          Center(child: Text(account.mailAddress!)),
        const SizedBox(height: 24),
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: Text(context.l10n.accountId),
          trailing: Text(account.id),
        ),
        if (account.authState == AccountAuthState.reauthRequired)
          ListTile(
            leading: const Icon(Icons.warning_amber_outlined),
            title: Text(context.l10n.reauthRequired),
          ),
        const Divider(),
        Text(
          context.l10n.profileReadOnly,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: () =>
              _openSettingsPage(context, const AccountSettingsPage()),
          child: Text(context.l10n.accountManagement),
        ),
      ],
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
        title: Text(context.l10n.accountManagement),
        actions: [
          IconButton(
            tooltip: context.l10n.addAccount,
            icon: const Icon(Icons.add),
            onPressed: () => openLogin(context),
          ),
        ],
      ),
      body: accounts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => SettingsLoadError(
          error: error,
          onRetry: () => ref.read(accountStoreProvider.notifier).reload(),
          messageKey: 'accountReadFailed',
        ),
        data: (state) => state.status == AccountStatus.failure
            ? SettingsLoadError(
                error: state.error ?? StateError('account state unavailable'),
                onRetry: () => ref.read(accountStoreProvider.notifier).reload(),
                messageKey: 'accountReadFailed',
              )
            : state.accounts.isEmpty
            ? Center(child: Text(context.l10n.noAccounts))
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
                          '${context.l10n.accountId}: ${account.id}',
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
                          tooltip: context.l10n.removeAccount,
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
        title: Text(context.l10n.removeAccount),
        content: Text(context.l10n.removeAccountConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.confirm),
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
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return _settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'themeSettings',
      );
    }
    final items = [
      (AppSettings.darkTheme, context.l10n.dark),
      (AppSettings.lightTheme, context.l10n.light),
      (AppSettings.systemTheme, context.l10n.system),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.themeSettings)),
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
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return _settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'languageSettings',
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.languageSettings)),
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
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return _settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'translateSettings',
      );
    }
    final items = [
      (
        TranslationProvider.disabled,
        context.l10n.translateDisabled,
      ),
      (TranslationProvider.baidu, context.l10n.translateBaidu),
      (
        TranslationProvider.translationLlm,
        context.l10n.translateLlm,
      ),
      (TranslationProvider.google, context.l10n.translateGoogle),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.translateSettings)),
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
          if (settings.translationProvider == TranslationProvider.baidu)
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: Text(context.l10n.translateBaiduCredential),
              onTap: () => _openTranslationCredentials(context, ref, true),
            ),
          if (settings.translationProvider ==
              TranslationProvider.translationLlm)
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: Text(context.l10n.translateLlmCredential),
              onTap: () => _openTranslationCredentials(context, ref, false),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              context.l10n.translateCredentialHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (settings.translationProvider == TranslationProvider.baidu)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                context.l10n.translateBaiduHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  void _openTranslationCredentials(
    BuildContext context,
    WidgetRef ref,
    bool baidu,
  ) {
    Navigator.of(context).push<void>(
      ReplicaPageRoute<void>(
        builder: (_) => TranslationCredentialsPage(baidu: baidu),
      ),
    );
  }
}

class TranslationCredentialsPage extends ConsumerStatefulWidget {
  const TranslationCredentialsPage({super.key, required this.baidu});

  final bool baidu;

  @override
  ConsumerState<TranslationCredentialsPage> createState() =>
      _TranslationCredentialsPageState();
}

class _TranslationCredentialsPageState
    extends ConsumerState<TranslationCredentialsPage> {
  final _appIdController = TextEditingController();
  final _secretController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();
  bool _saving = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _appIdController.dispose();
    _secretController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final store = ref.read(translationCredentialStoreProvider);
      if (widget.baidu) {
        final credentials = await store.readBaidu();
        if (credentials != null && mounted) {
          // Re-fill the form so a user can verify what is stored. Secret
          // values are filled into the obscured field only; they are never
          // rendered in status messages.
          _appIdController.text = credentials.appId;
          _secretController.text = credentials.secret;
        }
      } else {
        final credentials = await store.readLlm();
        if (credentials != null && mounted) {
          _baseUrlController.text = credentials.baseUrl;
          _apiKeyController.text = credentials.apiKey;
          _modelController.text = credentials.model ?? '';
        }
      }
    } on Object {
      if (mounted) {
        setState(
          () => _status = context.l10n.translateCredentialsStoreError,
        );
      }
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final store = ref.read(translationCredentialStoreProvider);
      if (widget.baidu) {
        final appId = _appIdController.text.trim();
        final secret = _secretController.text.trim();
        if (appId.isEmpty || secret.isEmpty) {
          throw const CommentTranslationError('incomplete baidu credentials');
        }
        await store.writeBaidu(
          BaiduTranslationCredentials(appId: appId, secret: secret),
        );
      } else {
        final baseUrl = _baseUrlController.text.trim();
        final apiKey = _apiKeyController.text.trim();
        final uri = Uri.tryParse(baseUrl);
        if (baseUrl.isEmpty ||
            apiKey.isEmpty ||
            uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty) {
          throw const CommentTranslationError('invalid LLM endpoint');
        }
        final model = _modelController.text.trim();
        await store.writeLlm(
          LlmTranslationCredentials(
            baseUrl: baseUrl,
            apiKey: apiKey,
            model: model.isEmpty ? null : model,
          ),
        );
      }
      if (mounted) {
        setState(
          () => _status = context.l10n.translateCredentialsSaved,
        );
      }
    } on CommentTranslationError {
      if (mounted) {
        setState(
          () => _status = context.l10n.translateCredentialsInvalid,
        );
      }
    } on TranslationCredentialsStoreException {
      if (mounted) {
        setState(
          () => _status = context.l10n.translateCredentialsStoreError,
        );
      }
    } on Object {
      if (mounted) {
        setState(
          () => _status = context.l10n.translateCredentialsStoreError,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final store = ref.read(translationCredentialStoreProvider);
      if (widget.baidu) {
        await store.deleteBaidu();
      } else {
        await store.deleteLlm();
      }
      if (mounted) {
        setState(() {
          _status = context.l10n.translateCredentialsCleared;
        });
      }
    } on TranslationCredentialsStoreException {
      if (mounted) {
        setState(
          () => _status = context.l10n.translateCredentialsStoreError,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _settingsText(
            context,
            widget.baidu
                ? 'translateBaiduCredential'
                : 'translateLlmCredential',
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.baidu)
            _credentialField(
              controller: _appIdController,
              label: context.l10n.translateBaiduAppId,
              obscure: false,
            )
          else
            _credentialField(
              controller: _baseUrlController,
              label: context.l10n.translateLlmBaseUrl,
              obscure: false,
              hint: 'https://api.example.com/v1',
            ),
          if (widget.baidu)
            _credentialField(
              controller: _secretController,
              label: context.l10n.translateBaiduSecret,
              obscure: true,
            )
          else
            _credentialField(
              controller: _apiKeyController,
              label: context.l10n.translateLlmApiKey,
              obscure: true,
            ),
          if (!widget.baidu)
            _credentialField(
              controller: _modelController,
              label: context.l10n.translateLlmModel,
              obscure: false,
            ),
          const SizedBox(height: 8),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _status!,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(context.l10n.translateCredentialsSave),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _saving ? null : _clear,
            icon: const Icon(Icons.delete_outline),
            label: Text(context.l10n.translateCredentialsClear),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              _settingsText(
                context,
                widget.baidu
                    ? 'translateBaiduHint'
                    : 'translateLlmCredentialHint',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _credentialField({
    required TextEditingController controller,
    required String label,
    required bool obscure,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class BrowseSettingsPage extends ConsumerWidget {
  const BrowseSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return _settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'browseSettings',
      );
    }
    final sources = [
      (
        AppSettings.normalImageSource,
        context.l10n.imageSourceNormal,
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.browseSettings)),
      body: ListView(
        children: [
          // C13: a single product option is not a meaningful choice; the
          // whole section is hidden until a second product-level image
          // source exists.
          if (sources.length > 1) ...[
            _SectionLabel(label: context.l10n.imageSource),
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
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              context.l10n.previewQuality,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final quality in PreviewQuality.values)
            _qualityTile(
              context,
              quality,
              settings.previewQuality,
              () => ref
                  .read(settingsProvider.notifier)
                  .setPreviewQuality(quality),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              context.l10n.detailQuality,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final quality in const [
            DetailQuality.large,
            DetailQuality.original,
          ])
            _qualityTile(
              context,
              quality,
              settings.detailQuality,
              () =>
                  ref.read(settingsProvider.notifier).setDetailQuality(quality),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              context.l10n.viewQuality,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final quality in const [ViewQuality.large, ViewQuality.original])
            _qualityTile(
              context,
              quality,
              settings.viewQuality,
              () => ref.read(settingsProvider.notifier).setViewQuality(quality),
            ),
          const Divider(),
          SwitchListTile(
            title: Text(context.l10n.pixivHistory),
            value: settings.enablePixivHistory,
            onChanged: (value) => _persistSettings(
              context,
              () => ref
                  .read(settingsProvider.notifier)
                  .setPixivHistoryEnabled(value),
            ),
          ),
          SwitchListTile(
            title: Text(context.l10n.blockR18),
            value: settings.enableLocalBlockR18,
            onChanged: (value) => _persistSettings(
              context,
              () => ref.read(settingsProvider.notifier).setLocalBlockR18(value),
            ),
          ),
          SwitchListTile(
            title: Text(context.l10n.blockAI),
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

String _qualityText(BuildContext context, Object quality) {
  return switch (quality) {
    PreviewQuality.medium ||
    ViewQuality.medium ||
    DetailQuality.medium => context.l10n.qualityMedium,
    PreviewQuality.large ||
    ViewQuality.large ||
    DetailQuality.large => context.l10n.qualityLarge,
    ViewQuality.original ||
    DetailQuality.original => context.l10n.qualityOriginal,
    _ => context.l10n.qualityLarge,
  };
}

Widget _qualityTile(
  BuildContext context,
  Object quality,
  Object current,
  Future<void> Function() action,
) {
  final selected = quality == current;
  return ListTile(
    title: Text(_qualityText(context, quality)),
    trailing: selected
        ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
        : null,
    onTap: () => _persistSettings(context, action),
  );
}

class DownloadSettingsPage extends ConsumerStatefulWidget {
  const DownloadSettingsPage({super.key});

  @override
  ConsumerState<DownloadSettingsPage> createState() =>
      _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends ConsumerState<DownloadSettingsPage> {
  late final TextEditingController _templateController;
  late final FocusNode _templateFocusNode;
  int? _draftMaxDownloads;

  @override
  void initState() {
    super.initState();
    _templateController = TextEditingController();
    _templateFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _templateController.dispose();
    _templateFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return _settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'downloadSettings',
      );
    }
    _draftMaxDownloads ??= settings.maxDownloadCount;
    final namingRule = settings.namingRule;
    if (!_templateFocusNode.hasFocus &&
        _templateController.text != (namingRule.template ?? '')) {
      _templateController.text = namingRule.template ?? '';
    }
    final destination = settings.downloadDestination;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.downloadSettings)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${context.l10n.maxDownloadCount}: $_draftMaxDownloads',
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
            onChangeEnd: (value) => _saveMaxDownloads(value.round()),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.saveLocation),
            subtitle: Text(_destinationText(context, destination)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
              ReplicaPageRoute<void>(
                builder: (_) => const DownloadDestinationPage(),
              ),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
            child: Text(
              context.l10n.namingPreset,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final preset in NamingPreset.values)
            ListTile(
              title: Text(_namingPresetText(context, preset)),
              trailing: namingRule.preset == preset
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => _persistSettings(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .setNamingRule(NamingRule(preset: preset)),
              ),
            ),
          if (namingRule.preset == NamingPreset.custom) ...[
            TextField(
              controller: _templateController,
              focusNode: _templateFocusNode,
              decoration: InputDecoration(
                labelText: context.l10n.namingTemplate,
                hintText: _settingsText(context, 'namingTemplateHint'),
                errorText: !NamingRule.isValidTemplate(_templateController.text)
                    ? context.l10n.namingTemplateInvalid
                    : null,
              ),
              maxLength: 128,
              onChanged: (_) => setState(() {}),
            ),
            Text(
              '${context.l10n.namingPreview}: '
              '${_previewName(context, namingRule.preset == NamingPreset.custom ? NamingRule(preset: NamingPreset.custom, template: _templateController.text) : namingRule)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.namingTemplateVariables(
                '{artist}', '{title}', '{id}', '{page}', '{ext}', '{date}',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            FilledButton(
              onPressed: () async {
                final template = _templateController.text.trim();
                if (!NamingRule.isValidTemplate(template)) return;
                final saved = await _persistSettings(
                  context,
                  () => ref
                      .read(settingsProvider.notifier)
                      .setNamingRule(
                        NamingRule(
                          preset: NamingPreset.custom,
                          template: template,
                        ),
                      ),
                );
                if (saved && context.mounted) {
                  showAppSnackBar(context, context.l10n.saved);
                }
              },
              child: Text(context.l10n.save),
            ),
          ],
        ],
      ),
    );
  }

  String _previewName(BuildContext context, NamingRule rule) {
    final preview = rule.preview(
      illustId: 123456,
      pageIndex: 0,
      extension: 'jpg',
      artist: '作者名',
      title: '作品标题',
      date: DateTime(2026, 9, 1),
    );
    return preview;
  }

  Future<void> _saveMaxDownloads(int value) async {
    final previous = _draftMaxDownloads;
    final saved = await _persistSettings(
      context,
      () => ref.read(settingsProvider.notifier).setMaxDownloadCount(value),
    );
    if (!saved && mounted) {
      final committed = ref.read(settingsProvider).value?.maxDownloadCount;
      setState(() => _draftMaxDownloads = committed ?? previous);
    }
  }
}

String _destinationText(BuildContext context, DownloadDestination destination) {
  return switch (destination.kind) {
    DownloadDestinationKind.pixivAlbum => context.l10n.saveLocationPixivAlbum,
    DownloadDestinationKind.customAlbum =>
      '${context.l10n.saveLocationCustomAlbum} '
          '(${destination.customAlbumName})',
    DownloadDestinationKind.safFolder => context.l10n.saveLocationSafFolder,
  };
}

String _namingPresetText(BuildContext context, NamingPreset preset) {
  return switch (preset) {
    NamingPreset.id => context.l10n.namingPresetId,
    NamingPreset.artistTitleId => context.l10n.namingPresetArtistTitleId,
    NamingPreset.titleId => context.l10n.namingPresetTitleId,
    NamingPreset.custom => context.l10n.namingPresetCustom,
  };
}

/// Single-entry save location chooser (D5): album vs SAF folder. Album
/// defaults to the built-in PixivFunc album with an optional custom name;
/// folder mode only accepts the system SAF tree URI.
class DownloadDestinationPage extends ConsumerStatefulWidget {
  const DownloadDestinationPage({super.key});

  @override
  ConsumerState<DownloadDestinationPage> createState() =>
      _DownloadDestinationPageState();
}

class _DownloadDestinationPageState
    extends ConsumerState<DownloadDestinationPage> {
  late final TextEditingController _albumController;
  late final FocusNode _albumFocusNode;

  @override
  void initState() {
    super.initState();
    _albumController = TextEditingController();
    _albumFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _albumController.dispose();
    _albumFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return _settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'saveLocation',
      );
    }
    final destination = settings.downloadDestination;
    if (!_albumFocusNode.hasFocus &&
        _albumController.text != (destination.customAlbumName ?? '')) {
      _albumController.text = destination.customAlbumName ?? '';
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.saveLocation)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: Text(context.l10n.saveLocationAlbum),
            trailing: !destination.isSafFolder
                ? Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
            onTap: () => _persistSettings(
              context,
              () => ref
                  .read(settingsProvider.notifier)
                  .setDownloadDestination(DownloadDestination.builtin),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 0, 0),
            child: TextField(
              controller: _albumController,
              focusNode: _albumFocusNode,
              decoration: InputDecoration(
                labelText: context.l10n.saveLocationCustomAlbum,
                helperText: context.l10n.saveLocationCustomAlbumHint,
              ),
              maxLength: 64,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 4, 0, 0),
            child: FilledButton.tonal(
              onPressed: () async {
                final name = DownloadDestination.normalizeAlbumName(
                  _albumController.text,
                );
                if (name == null) {
                  showAppSnackBar(context, context.l10n.saveLocationAlbumInvalid,);
                  return;
                }
                final saved = await _persistSettings(
                  context,
                  () => ref
                      .read(settingsProvider.notifier)
                      .setDownloadDestination(
                        DownloadDestination.customAlbum(name),
                      ),
                );
                if (saved && context.mounted) {
                  showAppSnackBar(context, context.l10n.saved);
                }
              },
              child: Text(context.l10n.saveLocationUseCustomAlbum),
            ),
          ),
          const Divider(),
          ListTile(
            title: Text(context.l10n.saveLocationSafFolder),
            subtitle: Text(context.l10n.saveLocationSafFolderHint),
            trailing: destination.isSafFolder
                ? Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
            onTap: () => _pickSafFolder(),
          ),
          if (destination.isSafFolder)
            ListTile(
              leading: const Icon(Icons.check_circle),
              title: Text(context.l10n.saveLocationSafPicked),
              subtitle: Text(destination.safTreeUri ?? ''),
            ),
        ],
      ),
    );
  }

  Future<void> _pickSafFolder() async {
    final uri = await ref.read(safTreePickerProvider).pickTree();
    if (uri == null || !mounted) return;
    final saved = await _persistSettings(
      context,
      () => ref
          .read(settingsProvider.notifier)
          .setDownloadDestination(DownloadDestination.safFolder(uri)),
    );
    if (saved && mounted) {
      showAppSnackBar(context, context.l10n.saved);
    }
  }
}

class HistorySettingsPage extends ConsumerWidget {
  const HistorySettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return _settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'historySettings',
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.historySettings)),
      body: ListView(
        children: [
          SwitchListTile(
            title: Text(context.l10n.localHistory),
            value: settings.enableHistory,
            onChanged: (value) => _persistSettings(
              context,
              () =>
                  ref.read(settingsProvider.notifier).setHistoryEnabled(value),
            ),
          ),
          SwitchListTile(
            title: Text(context.l10n.pixivHistory),
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
            title: Text(context.l10n.historyView),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openHistory(context),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              context.l10n.historySettingsHint,
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
          showAppSnackBar(context, '$error');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tags = ref.watch(blockedTagsProvider).toList()..sort();
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.blockTagSettings)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: context.l10n.blockTagInputHint,
              suffixIcon: IconButton(
                tooltip: context.l10n.add,
                icon: const Icon(Icons.add),
                onPressed: () => _addTag(_controller.text),
              ),
            ),
            onSubmitted: _addTag,
          ),
          const SizedBox(height: 12),
          if (tags.isEmpty)
            Center(child: Text(context.l10n.noBlockedTags))
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
      appBar: AppBar(title: Text(context.l10n.downloaderSettings)),
      body: tasks.isEmpty
          ? Center(child: Text(context.l10n.downloadTasksEmpty))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(context.l10n.downloaderSettingsHint),
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
                tooltip: context.l10n.cancelDownload,
                icon: const Icon(Icons.close),
                onPressed: () => manager.cancel(task.id),
              )
            : canRetry
            ? IconButton(
                tooltip: context.l10n.retryDownload,
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
      DownloadStatus.queued => context.l10n.downloadQueued,
      DownloadStatus.running => context.l10n.downloadRunning,
      DownloadStatus.finalizing => context.l10n.downloadRunning,
      DownloadStatus.canceling => context.l10n.downloadCanceling,
      DownloadStatus.succeeded => context.l10n.downloadSucceeded,
      DownloadStatus.failed => context.l10n.downloadFailed,
      DownloadStatus.canceled => context.l10n.downloadCanceled,
      DownloadStatus.retryable => context.l10n.downloadFailed,
      DownloadStatus.orphaned => context.l10n.downloadFailed,
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
      appBar: AppBar(title: Text(context.l10n.aboutSettings)),
      body: ListView(
        children: [
          const ListTile(
            leading: Icon(Icons.apps),
            title: Text('Pixiv Func'),
            subtitle: Text('0.1.0+1'),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(context.l10n.aboutVersion),
            trailing: const Text('0.1.0+1'),
          ),
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: Text(context.l10n.aboutLicense),
            subtitle: Text(context.l10n.aboutLicenseText),
            onTap: () => showLicensePage(
              context: context,
              applicationName: appName,
              applicationVersion: '0.1.0+1',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: Text(context.l10n.aboutAttribution),
            subtitle: Text(context.l10n.aboutAttributionText),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(context.l10n.aboutSource),
            subtitle: const Text('github.com/Lopution/Pixiv-func'),
          ),
          const Divider(),
          updateService.when(
            loading: () => ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: Text(context.l10n.aboutCheckUpdate),
              subtitle: Text(context.l10n.aboutCheckingUpdate),
            ),
            error: (_, _) => ListTile(
              leading: const Icon(Icons.warning_amber_outlined),
              title: Text(context.l10n.aboutCheckUpdate),
              subtitle: Text(context.l10n.aboutUpdateUnavailable),
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
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(context.l10n.aboutCheckingUpdate),
          );
        }
        final capability = snapshot.data;
        if (snapshot.hasError || capability == null) {
          return ListTile(
            leading: const Icon(Icons.warning_amber_outlined),
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(context.l10n.aboutUpdateUnavailable),
          );
        }
        if (capability.storeManaged ||
            capability.flavor == UpdateFlavor.fdroid) {
          return ListTile(
            leading: const Icon(Icons.store_outlined),
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(context.l10n.aboutUpdateStore),
          );
        }
        if (!capability.enabled) {
          return ListTile(
            leading: const Icon(Icons.warning_amber_outlined),
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(context.l10n.aboutUpdateUnavailable),
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
        '${context.l10n.aboutUpdateAvailable}: ${release!.manifest.version}',
      UpdateCheckStatus.disabled => context.l10n.aboutUpdateUnavailable,
      UpdateCheckStatus.noUpdate => context.l10n.aboutUpdateNoUpdate,
      UpdateCheckStatus.prerelease => context.l10n.aboutUpdatePrerelease,
      UpdateCheckStatus.invalid ||
      UpdateCheckStatus.rateLimited ||
      UpdateCheckStatus.offline ||
      UpdateCheckStatus.failed ||
      UpdateCheckStatus.busy => context.l10n.aboutUpdateFailed,
      null => null,
    };
    final applyText = switch (_applyResult?.status) {
      UpdateApplyStatus.installPermissionRequired => context.l10n.aboutUpdatePermission,
      UpdateApplyStatus.installStarted => context.l10n.aboutUpdateStarted,
      UpdateApplyStatus.failed ||
      UpdateApplyStatus.canceled => context.l10n.aboutUpdateFailed,
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
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(
              _checking || _applying
                  ? context.l10n.aboutUpdateDownloading
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
                  ? context.l10n.cancel
                  : release == null
                  ? context.l10n.aboutCheckUpdate
                  : context.l10n.aboutUpdateDownload,
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
        title: Text(context.l10n.aboutUpdateConfirmTitle),
        content: Text(context.l10n.aboutUpdateConfirmDetail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.confirm),
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
