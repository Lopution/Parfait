import 'package:flutter/material.dart';

import '../../core/i18n/replica_strings.dart';

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
  });

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    String text(String key) => ReplicaStrings.fromTag(
      Localizations.localeOf(context).toLanguageTag(),
      key,
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.settings_outlined, size: 48),
            const SizedBox(height: 12),
            Text(
              text('settingsReadFailed'),
              key: const Key('settings-load-error'),
            ),
            const SizedBox(height: 8),
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
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
