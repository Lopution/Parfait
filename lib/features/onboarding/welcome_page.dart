import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/func_tokens.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/scrollable_form_shell.dart';
import '../../l10n/lookup.dart';
import '../../app/theme/func_semantic_tokens.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final languageTag = Localizations.localeOf(context).toLanguageTag();
    return ScrollableFormShell(
      header: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Long translations wrap rather than shrink: the brand lockup
          // stays at its full size in every locale.
          for (final (index, key) in const [
            'welcome1',
            'welcome2',
          ].indexed) ...[
            if (index > 0) const SizedBox(height: FuncSpacing.xs),
            Text(
              l10nLookupFor(parseAppLocale(languageTag), key),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
          ],
        ],
      ),
      content: const SizedBox.shrink(),
      primaryAction: ReplicaButton(
        label: l10nLookupFor(parseAppLocale(languageTag), 'start'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: FuncTokens.lightBackground,
        onPressed: () => context.push<void>('/welcome/language'),
      ),
    );
  }
}
