import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    void next() => context.push<void>('/welcome/theme');

    return ScrollableFormShell(
      // Wrapping centered title — long translations take a second line
      // instead of shrinking to an unreadable size.
      header: Text(
        l10nLookupFor(language.locale, 'selectLanguage'),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in _items) ...[
            ReplicaSwitchTile(
              contentPadding: const EdgeInsets.symmetric(
                vertical: 6,
                horizontal: 24,
              ),
              value: settings.languageTag == item.$2,
              title: Text(
                item.$1,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              onTap: () =>
                  ref.read(settingsProvider.notifier).selectLanguage(item.$2),
            ),
            const Divider(),
          ],
        ],
      ),
      primaryAction: ReplicaButton(
        label: l10nLookupFor(language.locale, 'next'),
        backgroundColor: FuncTokens.primary,
        foregroundColor: FuncTokens.lightBackground,
        onPressed: next,
      ),
      // Skipping this step lands on the same next page; the choice stays
      // changeable in settings later.
      secondary: TextButton(
        onPressed: next,
        child: Text(l10nLookupFor(language.locale, 'setupLater')),
      ),
    );
  }
}
