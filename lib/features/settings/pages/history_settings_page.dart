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
      body: settingsNarrowBody(
        ListView(
          children: [
            SettingsControl(
              title: Text(context.l10n.localHistory),
              value: settings.enableHistory,
              onChanged: (value) => persistSettings(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .setHistoryEnabled(value),
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
            // The content view sits inside the configuration page it
            // belongs to; its subtitle reports the current switch states
            // so the entry also answers "is this recording anything".
            ListTile(
              leading: const Icon(Icons.history_outlined),
              title: Text(context.l10n.historyView),
              subtitle: Text(
                context.l10n.settingsHistorySummary(
                  settings.enableHistory
                      ? context.l10n.settingsSummaryOn
                      : context.l10n.settingsSummaryOff,
                  settings.enablePixivHistory
                      ? context.l10n.settingsSummaryOn
                      : context.l10n.settingsSummaryOff,
                ),
              ),
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
      ),
    );
  }
}
