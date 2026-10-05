import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/func_tokens.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/scrollable_form_shell.dart';
import '../../l10n/lookup.dart';
import '../../app/theme/func_semantic_tokens.dart';

/// First page of the guide: the app mark, a title and one line on what
/// comes next (language, then sign-in).
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  static const double _iconSize = 96;

  @override
  Widget build(BuildContext context) {
    final locale = parseAppLocale(
      Localizations.localeOf(context).toLanguageTag(),
    );
    String text(String key) => l10nLookupFor(locale, key);
    final theme = Theme.of(context);
    return ScrollableFormShell(
      // Long translations wrap rather than shrink.
      header: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Decoration: the title already names the app.
          Image.asset(
            'assets/branding/parfait_icon.png',
            width: _iconSize,
            height: _iconSize,
            excludeFromSemantics: true,
          ),
          const SizedBox(height: FuncSpacing.lg),
          Text(
            text('welcome1'),
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: FuncSpacing.sm),
          Text(
            text('welcome2'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      content: const SizedBox.shrink(),
      primaryAction: ReplicaButton(
        label: text('start'),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: FuncTokens.lightBackground,
        onPressed: () => context.push<void>('/welcome/language'),
      ),
    );
  }
}
