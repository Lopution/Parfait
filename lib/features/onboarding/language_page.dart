import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/replica_page_route.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../app/widgets/replica_switch_tile.dart';
import '../../app/widgets/settings_load_error.dart';
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
    return ref
        .watch(settingsProvider)
        .when(
          loading: () => const ReplicaScaffold(
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, stackTrace) => ReplicaScaffold(
            child: SettingsLoadError(
              error: error,
              onRetry: () => ref.read(settingsProvider.notifier).reload(),
            ),
          ),
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
            Text(
              ReplicaStrings.text(language, 'selectLanguage'),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            for (final item in _items) ...[
              ReplicaSwitchTile(
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 6,
                  horizontal: 24,
                ),
                value: settings.languageTag == item.$2,
                title: Text(
                  item.$1,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onTap: () =>
                    ref.read(settingsProvider.notifier).selectLanguage(item.$2),
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
                onPressed: () => Navigator.of(
                  context,
                ).push(ReplicaPageRoute<void>(builder: (_) => const ThemePage())),
              ),
            ),
            const Spacer(),
            Text(
              ReplicaStrings.text(language, 'later'),
              style: const TextStyle(fontSize: 14),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
