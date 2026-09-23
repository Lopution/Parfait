import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/func_tokens.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/scrollable_form_shell.dart';
import '../../l10n/lookup.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final languageTag = Localizations.localeOf(context).toLanguageTag();
    return ScrollableFormShell(
      header: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Single-line scaleDown: long translations shrink to fit instead
          // of wrapping to a second line, so the brand lockup's layout
          // anchor is identical in every locale.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              l10nLookupFor(parseAppLocale(languageTag), 'welcome1'),
              textAlign: TextAlign.center,
              maxLines: 1,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              l10nLookupFor(parseAppLocale(languageTag), 'welcome2'),
              textAlign: TextAlign.center,
              maxLines: 1,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: const SizedBox.shrink(),
      primaryAction: ReplicaButton(
        label: l10nLookupFor(parseAppLocale(languageTag), 'start'),
        backgroundColor: FuncTokens.primary,
        foregroundColor: FuncTokens.lightBackground,
        onPressed: () => context.push<void>('/welcome/language'),
      ),
    );
  }
}
