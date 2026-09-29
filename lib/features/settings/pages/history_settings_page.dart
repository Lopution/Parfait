import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/routes.dart' show openHistory;
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/settings/settings_control.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_tile.dart';
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
          padding: const EdgeInsets.only(
            top: FuncSpacing.sm,
            bottom: FuncSpacing.xl,
          ),
          children: [
            SettingsGroup(
              footer: Text(context.l10n.historySettingsHint),
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
                // belongs to; its subtitle reports the current switch
                // states so the entry also answers "is this recording
                // anything".
                SettingsTile(
                  icon: Icons.history_outlined,
                  title: context.l10n.historyView,
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
                  onTap: () => openHistory(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
