import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/motion/app_overlays.dart';
import '../../../app/navigation/routes.dart' show openLogin, openMe;
import '../../../app/person_avatar.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../app/widgets/settings/settings_control.dart';
import '../../../app/widgets/settings/settings_section.dart';
import '../../../app/widgets/settings_load_error.dart';
import '../../../core/auth/account.dart';
import '../../../core/auth/account_store.dart';
import '../../../core/settings/server_display_settings.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

class AccountCard extends StatelessWidget {
  const AccountCard({super.key, required this.account});

  final Account? account;

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
          style: FuncSemanticTokens.of(context).display,
        ),
        subtitle: Text(
          value == null
              ? context.l10n.accountProfile
              : value.mailAddress ?? '${context.l10n.accountId}: ${value.id}',
        ),
        trailing: value == null ? null : const Icon(Icons.chevron_right),
        onTap: value == null ? null : () => openMe(context),
      ),
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
            : ListView(
                children: [
                  for (final account in state.accounts)
                    ListTile(
                      leading: _AccountAvatar(account: account),
                      title: Text(account.name),
                      subtitle: Text(
                        account.mailAddress ??
                            '${context.l10n.accountId}: ${account.id}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (state.currentId == account.id)
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
                      onTap: state.currentId == account.id
                          ? null
                          : () => persistSettings(
                              context,
                              () => ref
                                  .read(accountStoreProvider.notifier)
                                  .switchAccount(account.id),
                            ),
                    ),
                  // Server-side display preferences only exist for a
                  // usable account; a signed-out/re-auth state shows the
                  // account rows alone.
                  if (state.usableCurrent != null) ...[
                    const Divider(),
                    const _ServerDisplaySection(),
                  ],
                ],
              ),
      ),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    Account account,
  ) async {
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
    if (remove != true || !context.mounted) return;
    await persistSettings(
      context,
      () => ref.read(accountStoreProvider.notifier).removeAccount(account.id),
    );
  }
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
  ) async {
    try {
      await action(ref.read(serverDisplaySettingsProvider.notifier));
    } on Object catch (error) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          '${context.l10n.serverDisplayWriteFailed}: $error',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(serverDisplaySettingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSection(title: Text(context.l10n.serverDisplaySettings)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            context.l10n.serverDisplayHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        settings.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => ListTile(
            leading: const Icon(Icons.error_outline),
            title: Text(context.l10n.serverDisplayLoadFailed),
            subtitle: Text('$error'),
            trailing: TextButton(
              onPressed: () => ref.invalidate(serverDisplaySettingsProvider),
              child: Text(context.l10n.retry),
            ),
          ),
          data: (value) => Column(
            children: [
              SettingsControl(
                title: Text(context.l10n.serverShowAi),
                value: value.showAi,
                onChanged: (v) => _write(
                  context,
                  ref,
                  (controller) => controller.setShowAi(v),
                ),
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
        ),
      ],
    );
  }
}
