import 'package:material_ui/material_ui.dart';

import '../../../core/download/download_recovery.dart' show DownloadFailureKind;
import '../../../core/errors/error_category.dart';
import '../../../core/logging/crash_log.dart';
import '../../../l10n/app_localizations.dart';
import '../../../l10n/context.dart';
import '../app_snack_bar.dart';
import '../../clipboard.dart';

/// Maps an [ErrorCategory] to its localized sentence — the single owner of
/// the category→copy mapping (C8/D1). Every error surface uses this instead
/// of printing raw exception text.
String errorCategoryText(BuildContext context, ErrorCategory category) =>
    errorCategoryTextL10n(context.l10n, category);

/// [AppLocalizations] twin of [errorCategoryText] for call sites that
/// already hold the bundle instead of a context (e.g. the download-task
/// presentation helpers).
String errorCategoryTextL10n(AppLocalizations l10n, ErrorCategory category) {
  return switch (category) {
    ErrorCategory.network => l10n.errorNetwork,
    ErrorCategory.timeout => l10n.errorTimeout,
    ErrorCategory.localNetwork => l10n.errorLocalNetwork,
    ErrorCategory.rateLimited => l10n.errorRateLimited,
    ErrorCategory.unauthorized => l10n.errorUnauthorized,
    ErrorCategory.server => l10n.errorServer,
    ErrorCategory.notFound => l10n.errorNotFound,
    ErrorCategory.parse => l10n.errorParse,
    ErrorCategory.storage => l10n.errorStorage,
    ErrorCategory.unknown => l10n.errorUnknown,
  };
}

/// Localized reason a download or a GIF export failed (C8/D1): the
/// five kinds with a generic meaning borrow the shared category sentence,
/// the download-only kinds (noSpace/permission/destination/resource/
/// ownership) get their own copy, and `unknown` maps through the category
/// table. `canceled` and `paused` are not errors and have no reason.
String? downloadFailureReasonText(
  AppLocalizations l10n,
  DownloadFailureKind? kind,
) => switch (kind) {
  null || DownloadFailureKind.canceled || DownloadFailureKind.paused => null,
  DownloadFailureKind.noSpace => l10n.downloadFailureNoSpace,
  DownloadFailureKind.permission => l10n.downloadFailurePermission,
  DownloadFailureKind.destination => l10n.downloadFailureDestination,
  DownloadFailureKind.resource => l10n.downloadFailureResource,
  DownloadFailureKind.ownership => l10n.downloadFailureOwnership,
  final k => errorCategoryTextL10n(l10n, categorizeDownloadFailure(k)),
};

/// Records a failure its surface shows in [CrashLog] and paints nothing
/// (ERR-02): the surface says what went wrong in the user's language, and
/// the raw error waits in the crash log, which 关于 exports for a bug
/// report. An error object is recorded once however often its surface
/// rebuilds or comes back on screen; a value without identity (a string)
/// once per mount.
class FailureReport extends StatefulWidget {
  const FailureReport({super.key, required this.action, required this.error});

  /// What failed, as the surface names it (its localized headline).
  final String action;
  final Object error;

  @override
  State<FailureReport> createState() => _FailureReportState();
}

class _FailureReportState extends State<FailureReport> {
  static final _recorded = Expando<bool>();

  @override
  void initState() {
    super.initState();
    _record();
  }

  @override
  void didUpdateWidget(FailureReport oldWidget) {
    super.didUpdateWidget(oldWidget);
    // An error object goes by identity, so a retry's equal but new error
    // is recorded; a string goes by value, so a rebuild's copy is not.
    if (_keyed(widget.error) || oldWidget.error != widget.error) _record();
  }

  /// Whether [error] can key an [Expando] (has identity).
  static bool _keyed(Object error) =>
      !(error is String || error is num || error is bool || error is Record);

  void _record() {
    final error = widget.error;
    if (_keyed(error)) {
      if (_recorded[error] ?? false) return;
      _recorded[error] = true;
    }
    CrashLog.report(widget.action, error);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Copies what the crash log holds about [error], for the surfaces that
/// come before the app's pages (startup, sign-in), where 关于 and its
/// crash-log export cannot be reached. Nothing raw shows on screen.
class CopyDiagnosticsButton extends StatelessWidget {
  const CopyDiagnosticsButton({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return TextButton.icon(
      onPressed: () => copyToClipboard(
        context,
        diagnosticText(error),
        message: l10n.diagnosticsCopied,
      ),
      icon: const Icon(Icons.copy_outlined, size: 18),
      label: Text(l10n.copyDiagnostics),
    );
  }
}

/// [error] as a diagnostics copy carries it, capped so a huge HTML dump
/// cannot flood the clipboard.
@visibleForTesting
String diagnosticText(Object error) {
  final raw = error.toString();
  return raw.length <= diagnosticMaxChars
      ? raw
      : '${raw.substring(0, diagnosticMaxChars)}…';
}

@visibleForTesting
const diagnosticMaxChars = 2000;

/// The one feedback shape for an operation that failed (D1): the prompt
/// shows "action: category" — never raw exception text — and the original
/// error plus stack land in [CrashLog] so a shared crash.log still carries
/// the diagnosis.
void showErrorSnackBar(
  BuildContext context, {
  required String action,
  required Object error,
  StackTrace? stack,
  PromptAction? snackBarAction,
  Duration duration = const Duration(seconds: 4),
}) {
  CrashLog.report(action, error, stack);
  showAppSnackBar(
    context,
    context.l10n.errorWithReason(
      action,
      errorCategoryText(context, categorizeError(error)),
    ),
    action: snackBarAction,
    duration: duration,
  );
}

/// [showErrorSnackBar] for a failure that may land after the context that
/// asked is gone: the prompt host and the texts are taken now, one prompt
/// per error category. A failure a store recorded comes without a stack.
void Function(Object error, [StackTrace? stack]) deferErrorSnackBar(
  BuildContext context, {
  required String action,
}) {
  final l10n = context.l10n;
  final prompts = {
    for (final category in ErrorCategory.values)
      category: deferAppSnackBar(
        context,
        l10n.errorWithReason(action, errorCategoryTextL10n(l10n, category)),
      ),
  };
  return (error, [stack]) {
    CrashLog.report(action, error, stack);
    prompts[categorizeError(error)]!();
  };
}
