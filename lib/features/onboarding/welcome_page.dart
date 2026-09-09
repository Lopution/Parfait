import 'package:flutter/material.dart';

import '../../app/motion/replica_page_route.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/replica_scaffold.dart';
import 'language_page.dart';
import '../../l10n/lookup.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final languageTag = Localizations.localeOf(context).toLanguageTag();
    return ReplicaScaffold(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontal = (constraints.maxWidth * .1).clamp(24.0, 48.0);
          final minHeight = (constraints.maxHeight - 48).clamp(
            0.0,
            double.infinity,
          );
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(horizontal, 24, horizontal, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 520,
                  minHeight: minHeight,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 48),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10nLookupFor(parseAppLocale(languageTag), 'welcome1'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10nLookupFor(parseAppLocale(languageTag), 'welcome2'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 48),
                    SizedBox(
                      width: double.infinity,
                      child: ReplicaButton(
                        label: l10nLookupFor(parseAppLocale(languageTag), 'start'),
                        backgroundColor: FuncTokens.primary,
                        foregroundColor: Colors.white,
                        onPressed: () => Navigator.of(context).push(
                          ReplicaPageRoute<void>(builder: (_) => const LanguagePage()),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
