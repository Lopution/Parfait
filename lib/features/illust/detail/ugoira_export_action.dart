import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/haptics/app_haptics.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/errors/error_details.dart';
import '../../../core/download/download_recovery.dart';
import '../../../core/logging/crash_log.dart';
import '../../../core/ugoira/ugoira_providers.dart';
import '../../../l10n/context.dart';

/// Launches an app-level Ugoira GIF export for [illustId] and delivers the
/// terminal result through the global [PromptHost] even if the caller's detail
/// page has been popped before export completes.
Future<void> startUgoiraGifExport(
  BuildContext context,
  WidgetRef ref,
  int illustId,
) async {
  final controller = ref.read(ugoiraExportControllerProvider.notifier);
  final existing = ref.read(ugoiraExportControllerProvider)[illustId];
  if (existing?.isActive == true) return;
  final l10n = context.l10n;
  if (!controller.isSignedIn) {
    AppHaptics.error();
    showAppSnackBar(context, l10n.ugoiraLoginRequired);
    return;
  }
  final present = deferAppSnackBarPresenter(context);
  final result = await controller.export(illustId);
  final kind = result.failureKind;
  final reason = kind == null || kind == DownloadFailureKind.unknown
      ? null
      : downloadFailureReasonText(l10n, kind);
  final message = switch (result.phase) {
    UgoiraExportPhase.succeeded => l10n.ugoiraSaved,
    UgoiraExportPhase.canceled => l10n.ugoiraSaveCanceled,
    _ when reason != null => l10n.errorWithReason(
      l10n.ugoiraSaveFailed,
      reason,
    ),
    _ => l10n.ugoiraSaveFailed,
  };
  if (result.phase == UgoiraExportPhase.failed) {
    CrashLog.record(StateError('ugoira export failed: ${result.error}'));
  }
  if (result.phase == UgoiraExportPhase.succeeded) {
    AppHaptics.success();
  } else if (result.phase != UgoiraExportPhase.canceled) {
    AppHaptics.error();
  }
  present(message);
}
