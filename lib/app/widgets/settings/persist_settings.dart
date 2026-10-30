import 'package:material_ui/material_ui.dart';

import '../../../l10n/context.dart';
import '../../../l10n/lookup.dart';
import '../errors/error_details.dart';

/// Looks a settings string up by key: entries whose l10n name does not match
/// the call-site contract (group footers, dynamic titles) go through the
/// generated lookup instead of a typed getter.
String settingsText(BuildContext context, String key) {
  return l10nLookup(context.l10n, key);
}

/// Wraps an immediate settings write: failures surface as a prompt and the
/// controller keeps the old value (SettingsController._writeTail rolls back).
/// The prompt host is taken before the write, so a failure that lands after
/// the page closed is still reported (FB-15). [failureMessageKey] selects
/// the failure text; defaults to the generic `settingsWriteFailed`.
Future<bool> persistSettings(
  BuildContext context,
  Future<void> Function() action, {
  String? failureMessageKey,
}) async {
  final reportFailure = deferErrorSnackBar(
    context,
    action: settingsText(context, failureMessageKey ?? 'settingsWriteFailed'),
  );
  try {
    await action();
    return true;
  } on Object catch (error, stack) {
    reportFailure(error, stack);
    return false;
  }
}
