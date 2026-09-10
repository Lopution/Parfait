import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

class ThemeSettingsPage extends ConsumerWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'themeSettings',
      );
    }
    final items = [
      (AppSettings.darkTheme, context.l10n.dark),
      (AppSettings.lightTheme, context.l10n.light),
      (AppSettings.systemTheme, context.l10n.system),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.themeSettings)),
      body: ListView(
        children: [
          for (final item in items)
            ListTile(
              title: Text(item.$2),
              trailing: settings.themeCode == item.$1
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => persistSettings(
                context,
                () => ref.read(settingsProvider.notifier).selectTheme(item.$1),
              ),
            ),
        ],
      ),
    );
  }
}
