import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import '../../core/errors/error_category.dart';
import '../../core/logging/crash_log.dart';
import '../../l10n/context.dart';
import '../haptics/app_haptics.dart';
import 'errors/error_details.dart';
import 'prompt_host.dart';

/// Captures the [ProviderContainer], [PromptHost] and localizations now so a
/// reversible action whose write finishes after an await (or after its page
/// pops) can still show its Undo prompt and restore cleanly (FB-08, FB-15).
void Function({
  required Future<void> Function(ProviderContainer container) onUndo,
})
deferUndoSnackBar(BuildContext context, String message) {
  final container = ProviderScope.containerOf(context, listen: false);
  final host = PromptHost.of(context);
  final l10n = context.l10n;
  return ({required onUndo}) {
    if (!host.mounted) return;
    Future<void> undo() async {
      try {
        await onUndo(container);
      } on Object catch (error, stack) {
        CrashLog.record(error, stack);
        if (!host.mounted) return;
        host.show(
          l10n.errorWithReason(
            l10n.undo,
            errorCategoryTextL10n(l10n, categorizeError(error)),
          ),
        );
      }
    }

    host.show(
      message,
      action: PromptAction(
        label: l10n.undo,
        // Undo landing is the light-tick role — the prompt is the visual
        // channel, the tick is redundant feedback.
        onPressed: () {
          AppHaptics.select();
          unawaited(undo());
        },
      ),
    );
  };
}

/// Feedback for a reversible action: the action already happened; Undo
/// puts it back (D5 — undo instead of a confirmation). The undo runs
/// against the [ProviderContainer] captured now, so it still works after
/// the page that showed it is gone. A failed undo reports through the
/// prompt host captured now, for the same reason.
void showUndoSnackBar(
  BuildContext context,
  String message, {
  required Future<void> Function(ProviderContainer container) onUndo,
}) {
  deferUndoSnackBar(context, message)(onUndo: onUndo);
}
