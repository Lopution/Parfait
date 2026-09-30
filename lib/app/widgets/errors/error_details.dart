import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/errors/error_category.dart';
import '../../../core/logging/crash_log.dart';
import '../../../l10n/app_localizations.dart';
import '../../../l10n/context.dart';
import '../../theme/func_semantic_tokens.dart';
import '../app_snack_bar.dart';

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
    ErrorCategory.rateLimited => l10n.errorRateLimited,
    ErrorCategory.unauthorized => l10n.errorUnauthorized,
    ErrorCategory.server => l10n.errorServer,
    ErrorCategory.notFound => l10n.errorNotFound,
    ErrorCategory.parse => l10n.errorParse,
    ErrorCategory.storage => l10n.errorStorage,
    ErrorCategory.unknown => l10n.errorUnknown,
  };
}

/// Collapsible "details" block: collapsed it is a low-emphasis button;
/// expanded it shows the raw technical text (`error.toString()`, capped)
/// in a selectable, copyable field. Error surfaces pair a localized
/// category sentence with this so the original failure stays reachable
/// for support without shouting stack noise at every failure (D1).
class ErrorDetails extends StatefulWidget {
  const ErrorDetails({super.key, required this.error});

  /// The raw error object; [Object.toString] is displayed verbatim.
  final Object error;

  /// Raw text is capped so a huge HTML dump cannot flood the surface.
  @visibleForTesting
  static const int maxChars = 2000;

  /// The disclosure's content area is capped at roughly twelve body lines.
  @visibleForTesting
  static const double maxContentHeight = 240;

  @override
  State<ErrorDetails> createState() => _ErrorDetailsState();
}

class _ErrorDetailsState extends State<ErrorDetails> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final raw = widget.error.toString();
    final text = raw.length <= ErrorDetails.maxChars
        ? raw
        : '${raw.substring(0, ErrorDetails.maxChars)}…';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The expanded state belongs on the button's own semantics node so
        // screen readers announce it; MergeSemantics folds the flag into
        // the button node TextButton creates.
        MergeSemantics(
          child: Semantics(
            expanded: _expanded,
            child: TextButton.icon(
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              label: Text(l10n.errorDetails),
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: FuncSpacing.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxHeight: ErrorDetails.maxContentHeight,
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                showAppSnackBar(context, l10n.errorDetailsCopied);
              }
            },
            icon: const Icon(Icons.copy_outlined, size: 16),
            label: Text(l10n.errorDetailsCopy),
          ),
        ],
      ],
    );
  }
}

/// The one feedback shape for an operation that failed (D1): the SnackBar
/// shows "action: category" — never raw exception text — and the original
/// error plus stack land in [CrashLog] so a shared crash.log still carries
/// the diagnosis.
void showErrorSnackBar(
  BuildContext context, {
  required String action,
  required Object error,
  StackTrace? stack,
  SnackBarAction? snackBarAction,
  Duration duration = const Duration(seconds: 4),
}) {
  CrashLog.record(error, stack);
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
