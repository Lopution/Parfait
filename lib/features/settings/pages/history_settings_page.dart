import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/routes.dart' show openHistory;
import '../../../app/widgets/settings/settings_control.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

class HistorySettingsPage extends ConsumerWidget {
  const HistorySettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return settingsUnavailable(
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
          SettingsControl(
            title: Text(context.l10n.localHistory),
            value: settings.enableHistory,
            onChanged: (value) => persistSettings(
              context,
              () =>
                  ref.read(settingsProvider.notifier).setHistoryEnabled(value),
            ),
          ),
          SettingsControl(
            title: Text(context.l10n.pixivHistory),
            value: settings.enablePixivHistory,
            onChanged: (value) => persistSettings(
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
