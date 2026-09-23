import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/routes.dart';
import '../../../app/widgets/app_snack_bar.dart';
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

  void _addTag(String value) {
    final tag = value.trim();
    if (tag.isEmpty) return;
    final store = ref.read(muteStoreProvider.notifier);
    if (ref.read(muteStoreProvider).isTagMuted(tag)) return;
    _controller.clear();
    _unmute(() => store.toggleTag(tag));
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
            _SectionHeader(l10n.mutedTagsSection),
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
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: l10n.unmuteTag,
                  onPressed: state.pending.contains(MuteKey.tag(tag))
                      ? null
                      : () => _unmute(() => store.toggleTag(tag)),
                ),
              ),
            const Divider(),
            _SectionHeader(l10n.mutedUsersSection),
            for (final user in users)
              ListTile(
                dense: true,
                title: Text(user.name),
                subtitle: user.account == null
                    ? null
                    : Text('@${user.account}'),
                onTap: () => openUser(context, user.userId),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: l10n.unmuteAuthor,
                  onPressed: state.pending.contains(MuteKey.user(user.userId))
                      ? null
                      : () => _unmute(() => store.toggleUser(user)),
                ),
              ),
            const Divider(),
            _SectionHeader(l10n.mutedWorksSection),
            for (final id in works)
              ListTile(
                dense: true,
                title: Text(
                  ref.watch(illustStoreProvider).get(id)?.title ?? '#$id',
                ),
                onTap: () => openIllust(context, id),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: l10n.unmuteWork,
                  onPressed: state.pending.contains(MuteKey.work(id))
                      ? null
                      : () => _unmute(() => store.toggleWork(id)),
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
