import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/replica_route.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../app/widgets/replica_switch_tile.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import 'theme_page.dart';

class LanguagePage extends ConsumerWidget {
  const LanguagePage({super.key});

  static const _items = <(String, String)>[
    ('简体中文', 'zh-CN'),
    ('English', 'en-US'),
    ('日本語', 'ja-JP'),
    ('Русский', 'ru-RU'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(settingsProvider).when(
          loading: () => const ReplicaScaffold(child: SizedBox.shrink()),
          error: (error, stackTrace) => const ReplicaScaffold(child: SizedBox.shrink()),
          data: (settings) => _buildContent(context, ref, settings),
        );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    final width = MediaQuery.sizeOf(context).width;
    final language = ReplicaLanguage.fromTag(settings.languageTag);
    return ReplicaScaffold(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: width * .1),
        child: Column(
          children: [
            const Spacer(flex: 2),
            const Text('选择您的语言', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const Text('Select your language', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const Text('言語を選択', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const Text('Выберите свой язык', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const Spacer(),
            for (final item in _items) ...[
              ReplicaSwitchTile(
                contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
                value: settings.languageTag == item.$2,
                title: Text(
                  item.$1,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                onTap: () => ref.read(settingsProvider.notifier).selectLanguage(item.$2),
              ),
              const Divider(),
            ],
            const Spacer(flex: 2),
            SizedBox(
              width: double.infinity,
              child: ReplicaButton(
                label: ReplicaStrings.text(language, 'next'),
                backgroundColor: FuncTokens.primary,
                foregroundColor: Colors.white,
                onPressed: () => Navigator.of(context).push(
                  replicaRoute((context) => const ThemePage()),
                ),
              ),
            ),
            const Spacer(),
            const Text('稍后您可以在设置中进行相应变更', style: TextStyle(fontSize: 14)),
            const Text('You can change the settings later', style: TextStyle(fontSize: 14)),
            const Text('後で設定を変更できます', style: TextStyle(fontSize: 14)),
            const Text('Вы можете изменить его позже в настройках', style: TextStyle(fontSize: 14)),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
