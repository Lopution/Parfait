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
import '../login/login_page.dart';

class ThemePage extends ConsumerWidget {
  const ThemePage({super.key});

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
    String text(String key) => ReplicaStrings.text(language, key);

    return ReplicaScaffold(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: width * .1),
        child: Column(
          children: [
            const Spacer(flex: 2),
            Text(
              text('selectTheme'),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            ReplicaSwitchTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
              value: settings.themeCode == AppSettings.darkTheme,
              title: Text(text('dark'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              onTap: () => ref.read(settingsProvider.notifier).selectTheme(AppSettings.darkTheme),
            ),
            const Divider(),
            ReplicaSwitchTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
              value: settings.themeCode == AppSettings.lightTheme,
              title: Text(text('light'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              onTap: () => ref.read(settingsProvider.notifier).selectTheme(AppSettings.lightTheme),
            ),
            const Divider(),
            ReplicaSwitchTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
              value: settings.themeCode == AppSettings.systemTheme,
              title: Text(text('system'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              onTap: () => ref.read(settingsProvider.notifier).selectTheme(AppSettings.systemTheme),
            ),
            const Spacer(flex: 2),
            SizedBox(
              width: double.infinity,
              child: ReplicaButton(
                label: text('next'),
                backgroundColor: FuncTokens.primary,
                foregroundColor: Colors.white,
                onPressed: () async {
                  await ref.read(settingsProvider.notifier).completeGuide();
                  if (!context.mounted) return;
                  await Navigator.of(context).push(
                    replicaRoute((context) => const LoginPage(isFirst: true)),
                  );
                },
              ),
            ),
            const Spacer(),
            Text(text('later'), style: const TextStyle(fontSize: 14)),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
