import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/routes.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/settings/settings_section.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/mute/mute_models.dart';
import '../../../core/mute/mute_store.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

/// Muted items management: tags and users mirror the official client's
/// `/v1/mute` list; works are local-only (no official endpoint). Removing
/// an entry sends the matching `mute/edit` delete and rolls back on
/// failure — the row reappears and the error is surfaced.
class MutedItemsPage extends ConsumerStatefulWidget {
  const MutedItemsPage({super.key});

  @override
  ConsumerState<MutedItemsPage> createState() => _MutedItemsPageState();
}

class _MutedItemsPageState extends ConsumerState<MutedItemsPage> {
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

  void _unmute(Future<void> Function() action) {
    unawaited(
      action().catchError((Object error) {
        if (mounted) showAppSnackBar(context, '$error');
      }),
    );
  }

  Future<void> _addTag(String value) async {
    final tag = value.trim();
    if (tag.isEmpty) return;
    final store = ref.read(muteStoreProvider.notifier);
    if (ref.read(muteStoreProvider).isTagMuted(tag)) return;
    try {
      await store.toggleTag(tag);
      if (mounted) _controller.clear();
    } on Object catch (error) {
      if (mounted) showAppSnackBar(context, '$error');
    }
  }

  /// Unmute affordance (D6): the visibility icon reads as "show again";
  /// while the write is in flight the slot shows a spinner instead of a
  /// dead disabled button so the pending state is visible.
  Widget _unmuteTrailing({
    required bool pending,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    if (pending) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.visibility_outlined),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(muteStoreProvider);
    final store = ref.read(muteStoreProvider.notifier);
    final tags = state.tags.toList()..sort();
    final users = state.users.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final works = state.workIds.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.mutedItemsSettings)),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SettingsSection(title: Text(l10n.mutedTagsSection)),
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                labelText: l10n.muteTagInputHint,
                suffixIcon: IconButton(
                  tooltip: l10n.add,
                  icon: const Icon(Icons.add),
                  onPressed: () => _addTag(_controller.text),
                ),
              ),
              onSubmitted: _addTag,
            ),
            for (final tag in tags)
              ListTile(
                dense: true,
                title: Text(tag),
                onTap: () => openTagSearch(context, tag),
                trailing: _unmuteTrailing(
                  pending: state.pending.contains(MuteKey.tag(tag)),
                  tooltip: l10n.unmuteTag,
                  onPressed: () => _unmute(() => store.toggleTag(tag)),
                ),
              ),
            const Divider(),
            SettingsSection(title: Text(l10n.mutedUsersSection)),
            for (final user in users)
              ListTile(
                dense: true,
                title: Text(user.name),
                subtitle: user.account == null
                    ? null
                    : Text('@${user.account}'),
                onTap: () => openUser(context, user.userId),
                trailing: _unmuteTrailing(
                  pending: state.pending.contains(MuteKey.user(user.userId)),
                  tooltip: l10n.unmuteAuthor,
                  onPressed: () => _unmute(() => store.toggleUser(user)),
                ),
              ),
            const Divider(),
            SettingsSection(title: Text(l10n.mutedWorksSection)),
            for (final id in works)
              ListTile(
                dense: true,
                title: Text(
                  ref.watch(illustStoreProvider).get(id)?.title ?? '#$id',
                ),
                onTap: () => openIllust(context, id),
                trailing: _unmuteTrailing(
                  pending: state.pending.contains(MuteKey.work(id)),
                  tooltip: l10n.unmuteWork,
                  onPressed: () => _unmute(() => store.toggleWork(id)),
                ),
              ),
            if (tags.isEmpty && users.isEmpty && works.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(child: Text(l10n.mutedEmpty)),
              ),
          ],
        ),
      ),
    );
  }
}
