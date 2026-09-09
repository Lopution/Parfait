import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/routes.dart'
    show openLogin, openMe, openProfileEdit;
import '../../../app/person_avatar.dart';
import '../../../app/widgets/settings_load_error.dart';
import '../../../core/auth/account.dart';
import '../../../core/auth/account_store.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

class AccountCard extends StatelessWidget {
  const AccountCard({super.key, required this.account, this.onLongPress});

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
              : value.mailAddress ?? '${context.l10n.accountId}: ${value.id}',
        ),
        trailing: value == null ? null : const Icon(Icons.chevron_right),
        onTap: value == null
            ? null
            : () => openMe(
                context,
                onEditProfile: () => openProfileEdit(context, value.userId),
              ),
        onLongPress: onLongPress,
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
                        : () => persistSettings(
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
    await persistSettings(
      context,
      () => ref.read(accountStoreProvider.notifier).removeAccount(account.id),
    );
  }
}
