import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/routes.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../app/widgets/scrollable_form_shell.dart';
import '../../app/widgets/settings/settings_choice_tile.dart';
import '../../app/widgets/settings/settings_group.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/i18n/replica_language.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/lookup.dart';

/// The guide's only setup step: pick a language, then sign in. The choice
/// applies as soon as it is tapped — this page's own text follows it.
/// Theme and everything else stay in settings.
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
    String text(String key) => l10nLookupFor(language.locale, key);

    Future<void> next() async {
      await ref.read(settingsProvider.notifier).completeGuide();
      if (!context.mounted) return;
      await openLogin(context, isFirst: true, returnToHomeOnSuccess: true);
    }

    return ScrollableFormShell(
      // Wrapping centered title — long translations take a second line
      // instead of shrinking to an unreadable size.
      header: Text(
        text('selectLanguage'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      content: SettingsGroup(
        children: [
          for (final (name, tag) in _items)
            SettingsChoiceTile(
              selected: settings.languageTag == tag,
              title: Text(name),
              onTap: () =>
                  ref.read(settingsProvider.notifier).selectLanguage(tag),
            ),
        ],
      ),
      primaryAction: ReplicaButton(
        label: text('next'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: FuncTokens.lightBackground,
        onPressed: next,
      ),
    );
  }
}
