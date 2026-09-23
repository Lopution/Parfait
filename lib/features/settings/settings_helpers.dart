import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/layout/content_widths.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';

String settingsText(BuildContext context, String key) {
  return l10nLookup(context.l10n, key);
}

/// The settings column cap (D1): on wide surfaces the page body is centered
/// at [ContentWidths.settings]; below the cap the constraint is a no-op, so
/// there is no breakpoint branch.
Widget settingsNarrowBody(Widget child) => Center(
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: ContentWidths.settings),
    child: child,
  ),
);

/// Wraps an immediate settings write: failures surface as a snackbar and the
/// controller keeps the old value (SettingsController._writeTail rolls back).
/// [failureMessageKey] selects the failure text; defaults to the generic
/// `settingsWriteFailed`.
Future<bool> persistSettings(
  BuildContext context,
  Future<void> Function() action, {
  String? failureMessageKey,
}) async {
  try {
    await action();
    return true;
  } on Object catch (error) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        '${settingsText(context, failureMessageKey ?? 'settingsWriteFailed')}: '
        '$error',
      );
    }
    return false;
  }
}

Widget settingsUnavailable(
  BuildContext context,
  WidgetRef ref,
  AsyncValue<AppSettings> state, {
  required String titleKey,
}) {
  return Scaffold(
    appBar: AppBar(title: Text(settingsText(context, titleKey))),
    body: state.when(
      loading: () => const FeedLoading(),
      error: (error, _) => SettingsLoadError(
        error: error,
        onRetry: () => ref.read(settingsProvider.notifier).reload(),
      ),
      // AsyncData<AppSettings> is never null; this branch only keeps the
      // helper total if the provider implementation changes later.
      data: (_) => const SizedBox.shrink(),
    ),
  );
}

void openSettingsPage(BuildContext context, String path) {
  context.push<void>(path);
}
