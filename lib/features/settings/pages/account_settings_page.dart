import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/motion/app_overlays.dart';
import '../../../app/motion/removal.dart';
import '../../../app/navigation/routes.dart' show openLogin, openMe;
import '../../../app/person_avatar.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../app/widgets/settings/settings_action_tile.dart';
import '../../../app/widgets/settings/settings_control.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_group_content.dart';
import '../../../app/widgets/settings/settings_tile.dart';
import '../../../app/widgets/errors/error_details.dart';
import '../../../app/widgets/settings_load_error.dart';
import '../../../core/auth/account.dart';
import '../../../core/auth/account_store.dart';
import '../../../core/auth/account_transfer.dart';
import '../../../core/auth/account_transfer_service.dart';
import '../../../core/errors/error_category.dart';
import '../../../core/settings/server_display_settings.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

String _accountSubtitle(BuildContext context, Account account) =>
    context.l10n.labelValue(context.l10n.accountId, account.id);

/// Signed-in account summary on the settings hub: 58dp avatar and display
/// type, not a settings row — it lives inside the first [SettingsGroup] and
/// opens the profile page.
class AccountSummaryTile extends StatelessWidget {
  const AccountSummaryTile({super.key, required this.account});

  final Account? account;

  @override
  Widget build(BuildContext context) {
    final value = account;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: FuncSpacing.lg,
        vertical: FuncSpacing.sm,
      ),
      leading: _AccountAvatar(account: value),
      title: Text(
        value?.name ?? context.l10n.signedOut,
        style: FuncSemanticTokens.of(context).display,
      ),
      subtitle: Text(
        value == null ? context.l10n.login : _accountSubtitle(context, value),
      ),
      trailing: const Icon(Icons.chevron_right),
      // A signed-out card used to be a dead end; it opens the login page.
      onTap: value == null ? () => openLogin(context) : () => openMe(context),
    );
  }
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

class AccountSettingsPage extends ConsumerStatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  ConsumerState<AccountSettingsPage> createState() =>
      _AccountSettingsPageState();
}

class _AccountSettingsPageState extends ConsumerState<AccountSettingsPage> {
  final _removals = RemovalController();

  /// Id of the account a switch is committing to, or null when idle.
  /// `switchAccount` is an action write (metadata save + network session
  /// reset), not an instant toggle — the target row spins and every row's
  /// tap/remove affordances disable while it runs so a second switch or a
  /// remove cannot race the commit.
  String? _switchingTo;

  Future<void> _switchTo(Account account) async {
    if (_switchingTo != null) return;
    setState(() => _switchingTo = account.id);
    try {
      await persistSettings(
        context,
        () => ref.read(accountStoreProvider.notifier).switchAccount(account.id),
      );
    } finally {
      if (mounted) setState(() => _switchingTo = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountStoreProvider);
    return Scaffold(
      appBar: AppTopBar(
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
        loading: () => const FeedLoading(),
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
            : settingsNarrowBody(
                RemovalScope(
                  controller: _removals,
                  child: ListView(
                    padding: const EdgeInsets.only(
                      top: FuncSpacing.sm,
                      bottom: FuncSpacing.xl,
                    ),
                    children: [
                      SettingsGroup(
                        children: [
                          for (final account in state.accounts)
                            Removable(
                              id: account.id,
                              child: ListTile(
                                // Same selected-state second channel as the
                                // theme/language pickers (check icon for
                                // sighted users, `selected` for assistive
                                // tech).
                                selected: state.currentId == account.id,
                                leading: _AccountAvatar(account: account),
                                title: Text(account.name),
                                subtitle: Text(
                                  _accountSubtitle(context, account),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_switchingTo == account.id)
                                      SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: Center(
                                          child: SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              semanticsLabel:
                                                  context.l10n.accountSwitching,
                                            ),
                                          ),
                                        ),
                                      )
                                    else if (state.currentId == account.id)
                                      Icon(
                                        Icons.check,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                    IconButton(
                                      tooltip: context.l10n.removeAccount,
                                      // Destructive, so it does not take
                                      // the selected row's primary tint.
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: _switchingTo == null
                                          ? () => _confirmRemove(account)
                                          : null,
                                    ),
                                  ],
                                ),
                                onTap:
                                    state.currentId == account.id ||
                                        _switchingTo != null
                                    ? null
                                    : () => _switchTo(account),
                              ),
                            ),
                          // Credential export is a visible entry, not a
                          // hidden gesture: the tile exists only for a
                          // signed-in account and the warning dialog still
                          // gates the actual copy.
                          if (state.current != null)
                            SettingsTile(
                              icon: Icons.send_to_mobile,
                              title: context.l10n.accountTransferExportTitle,
                              onTap: _confirmCopyAccount,
                            ),
                        ],
                      ),
                      // Server-side display preferences only exist for a
                      // usable account; a signed-out/re-auth state shows the
                      // account rows alone.
                      if (state.usableCurrent != null)
                        const _ServerDisplaySection(),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _confirmRemove(Account account) async {
    final remove = await showAppDialog<bool>(
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
    if (remove != true || !mounted) return;
    // The row leaves first; a failed save brings it back.
    final store = ref.read(accountStoreProvider.notifier);
    await _removals.playExit([account.id]);
    // Confirmed is confirmed: a page closed mid-exit still removes.
    if (!mounted) {
      unawaited(store.removeAccount(account.id));
      return;
    }
    final saved = await persistSettings(
      context,
      () => store.removeAccount(account.id),
    );
    if (!saved) _removals.restore([account.id]);
  }

  /// Credential export is destructive-adjacent (plaintext tokens on the
  /// system clipboard): the entry is a visible tile, and this dialog carries
  /// the warning before any byte is copied.
  Future<void> _confirmCopyAccount() async {
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
    if (confirmed == true && mounted) {
      _copyAccount();
    }
  }

  void _copyAccount() {
    unawaited(() async {
      try {
        await ref
            .read(accountTransferServiceProvider)
            .exportCurrentToClipboard();
        if (!mounted) return;
        showAppSnackBar(context, context.l10n.accountTransferCopied);
        // Android <13 cannot mark the clipboard entry as sensitive; the
        // credential sits in the system clipboard in plaintext. Never do
        // this silently (R4: 安全降级，不能静默少做一件事).
        final capabilities = await ref
            .read(transferClipboardProvider)
            .capabilities();
        if (!capabilities.sensitiveMarkSupported && mounted) {
          showAppSnackBar(
            context,
            context.l10n.accountTransferSensitiveWarning,
            duration: const Duration(seconds: 5),
            replaceCurrent: false,
          );
        }
      } on AccountTransferException catch (error) {
        if (!mounted) return;
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

/// Server-authoritative display preferences of the current account. The
/// toggles update optimistically through [ServerDisplaySettingsController]
/// and roll back with a visible error when the server edit fails.
class _ServerDisplaySection extends ConsumerWidget {
  const _ServerDisplaySection();

  Future<void> _write(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function(ServerDisplaySettingsController) action,
  ) {
    return persistSettings(
      context,
      () => action(ref.read(serverDisplaySettingsProvider.notifier)),
      failureMessageKey: 'serverDisplayWriteFailed',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(serverDisplaySettingsProvider);
    return SettingsGroup(
      title: Text(context.l10n.serverDisplaySettings),
      footer: Text(context.l10n.serverDisplayHint),
      children: settings.when(
        loading: () => const [
          SettingsGroupContent(
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
        error: (error, _) => [
          SettingsActionTile(
            icon: Icons.error_outline,
            title: Text(context.l10n.serverDisplayLoadFailed),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(errorCategoryText(context, categorizeError(error))),
                ErrorDetails(error: error),
              ],
            ),
            trailing: TextButton(
              onPressed: () => ref.invalidate(serverDisplaySettingsProvider),
              child: Text(context.l10n.retry),
            ),
          ),
        ],
        data: (value) => [
          SettingsControl(
            title: Text(context.l10n.serverShowAi),
            value: value.showAi,
            onChanged: (v) =>
                _write(context, ref, (controller) => controller.setShowAi(v)),
          ),
          SettingsControl(
            title: Text(context.l10n.serverRestrictedMode),
            value: value.restrictedMode,
            onChanged: (v) => _write(
              context,
              ref,
              (controller) => controller.setRestrictedMode(v),
            ),
          ),
        ],
      ),
    );
  }
}
