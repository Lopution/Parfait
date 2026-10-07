import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/settings/settings_choice_tile.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

class LanguageSettingsPage extends ConsumerWidget {
  const LanguageSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'languageSettings',
      );
    }
    return Scaffold(
      appBar: AppTopBar(title: Text(context.l10n.languageSettings)),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.only(
            top: FuncSpacing.sm,
            bottom: FuncSpacing.xl,
          ),
          children: [
            SettingsGroup(
              children: [
                for (final item in languageItems)
                  SettingsChoiceTile(
                    selected: settings.languageTag == item.$2,
                    title: Text(item.$1),
                    onTap: () => persistSettings(
                      context,
                      () => ref
                          .read(settingsProvider.notifier)
                          .selectLanguage(item.$2),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
