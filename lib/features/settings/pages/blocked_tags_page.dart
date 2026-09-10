import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/app_snack_bar.dart';
import '../../../core/settings/blocked_tags.dart';
import '../../../l10n/context.dart';

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
