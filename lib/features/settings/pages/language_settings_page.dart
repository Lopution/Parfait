import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

class LanguageSettingsPage extends ConsumerWidget {
  const LanguageSettingsPage({super.key});

  static const _items = [
    ('简体中文', 'zh-CN'),
    ('English', 'en-US'),
    ('日本語', 'ja-JP'),
    ('Русский', 'ru-RU'),
  ];

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
      appBar: AppBar(title: Text(context.l10n.languageSettings)),
      body: ListView(
        children: [
          for (final item in _items)
            ListTile(
              title: Text(item.$1),
              trailing: settings.languageTag == item.$2
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => persistSettings(
                context,
                () =>
                    ref.read(settingsProvider.notifier).selectLanguage(item.$2),
              ),
            ),
        ],
      ),
    );
  }
}
