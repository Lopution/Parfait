import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/errors/error_category.dart';
import '../../core/logging/crash_log.dart';
import '../../l10n/context.dart';
import '../haptics/app_haptics.dart';
import 'app_snack_bar.dart';
import 'errors/error_details.dart';

/// Feedback for a reversible action: the action already happened; Undo
/// puts it back (D5 — undo instead of a confirmation). The undo runs
/// against the [ProviderContainer] captured now, so it still works after
/// the page that showed it is gone. A failed undo reports through the
/// messenger captured now, for the same reason.
void showUndoSnackBar(
  BuildContext context,
  String message, {
  required Future<void> Function(ProviderContainer container) onUndo,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l10n = context.l10n;
  Future<void> undo() async {
    try {
      await onUndo(container);
    } on Object catch (error, stack) {
      CrashLog.record(error, stack);
      if (messenger == null || !messenger.mounted) return;
      showAppSnackBarOn(
        messenger,
        l10n.errorWithReason(
          l10n.undo,
          errorCategoryTextL10n(l10n, categorizeError(error)),
        ),
      );
    }
  }

  showAppSnackBar(
    context,
    message,
    action: SnackBarAction(
      label: l10n.undo,
      // Undo landing is the light-tick role — the snackbar is the visual
      // channel, the tick is redundant feedback.
      onPressed: () {
        AppHaptics.select();
        unawaited(undo());
      },
    ),
  );
}
