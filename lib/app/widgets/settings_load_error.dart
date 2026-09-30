import 'package:material_ui/material_ui.dart';

import '../../core/errors/error_category.dart';
import '../../l10n/lookup.dart';
import '../../l10n/context.dart';
import 'errors/error_details.dart';
import '../theme/func_semantic_tokens.dart';

/// Shared "settings could not be read" body with a working retry.
///
/// Every entry point that reads [settingsProvider] before it has a value
/// needs this: the startup gate, the settings page and the login page. It
/// reports the failure instead of falling back to defaults — signing in or
/// browsing under a language and network mode the user never chose would
/// hide a real storage error.
///
/// Its copy resolves from the ambient locale, not from settings: the branch
/// that renders it is precisely the one where settings are unavailable.
class SettingsLoadError extends StatelessWidget {
  const SettingsLoadError({
    super.key,
    required this.error,
    required this.onRetry,
    this.messageKey = 'settingsReadFailed',
  });

  final Object error;
  final VoidCallback onRetry;
  final String messageKey;

  @override
  Widget build(BuildContext context) {
    String text(String key) => l10nLookup(context.l10n, key);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(FuncSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.settings_outlined, size: 48),
            const SizedBox(height: FuncSpacing.md),
            Text(text(messageKey), key: const Key('settings-load-error')),
            const SizedBox(height: FuncSpacing.sm),
            Text(
              errorCategoryText(context, categorizeError(error)),
              textAlign: TextAlign.center,
            ),
            ErrorDetails(error: error),
            const SizedBox(height: FuncSpacing.md),
            FilledButton(
              key: const Key('settings-load-retry'),
              onPressed: onRetry,
              child: Text(text('retry')),
            ),
          ],
        ),
      ),
    );
  }
}
