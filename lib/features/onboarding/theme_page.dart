import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/routes.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../app/widgets/replica_switch_tile.dart';
import '../../app/widgets/scrollable_form_shell.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/i18n/replica_language.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/lookup.dart';

class ThemePage extends ConsumerWidget {
  const ThemePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(settingsProvider)
        .when(
          loading: () => const ReplicaScaffold(child: FeedLoading()),
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
    final language = ReplicaLanguage.fromTag(settings.languageTag);
    String text(String key) => l10nLookupFor(language.locale, key);

    // Both the primary action and the "set up later" affordance finish the
    // guide and continue to login — the theme stays changeable in settings.
    Future<void> next() async {
      await ref.read(settingsProvider.notifier).completeGuide();
      if (!context.mounted) return;
      await openLogin(context, isFirst: true, returnToHomeOnSuccess: true);
    }

    Widget option(int themeCode, String label) => ReplicaSwitchTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 6),
      value: settings.themeCode == themeCode,
      title: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
      ),
      onTap: () => ref.read(settingsProvider.notifier).selectTheme(themeCode),
    );

    return ScrollableFormShell(
      // Wrapping centered title, same treatment as the language page.
      header: Text(
        text('selectTheme'),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          option(AppSettings.darkTheme, text('dark')),
          const Divider(),
          option(AppSettings.lightTheme, text('light')),
          const Divider(),
          option(AppSettings.systemTheme, text('system')),
        ],
      ),
      primaryAction: ReplicaButton(
        label: text('next'),
        backgroundColor: FuncTokens.primary,
        foregroundColor: FuncTokens.lightBackground,
        onPressed: () => next(),
      ),
      secondary: TextButton(
        onPressed: () => next(),
        child: Text(text('setupLater')),
      ),
    );
  }
}
