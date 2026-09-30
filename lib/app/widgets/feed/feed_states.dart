import 'package:material_ui/material_ui.dart';

import '../../../core/errors/error_category.dart';
import '../../../core/paging/paged_feed_controller.dart';
import '../errors/error_details.dart';
import '../../theme/func_semantic_tokens.dart';

/// Shared feed-tail widget: load-more spinner, load-more error + retry and
/// the exhausted marker. Consumes [PagedFeedState] phase semantics; text and
/// retry wiring stay caller-owned (i18n accessors live at the call site).
class FeedTail extends StatelessWidget {
  const FeedTail({
    super.key,
    required this.feed,
    this.onRetry,
    this.errorTitle,
    required this.retryLabel,
    this.endMessage,
    this.padding = const EdgeInsets.all(FuncSpacing.lg),
  });

  final PagedFeedState feed;
  final VoidCallback? onRetry;

  /// Optional translated title shown above the load-more error row.
  final String? errorTitle;
  final String retryLabel;

  /// Optional translated marker rendered when the feed is exhausted.
  final String? endMessage;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (feed.showLoadMoreSpinner) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(FuncSpacing.lg),
          child: CircularProgressIndicator(),
        ),
      );
    }
    final loadMoreError = feed.loadMoreError;
    if (feed.showLoadMoreError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (errorTitle != null) Text(errorTitle!),
              if (loadMoreError != null) ...[
                Text(
                  errorCategoryText(context, categorizeError(loadMoreError)),
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                ErrorDetails(error: loadMoreError),
              ],
              TextButton(onPressed: onRetry, child: Text(retryLabel)),
            ],
          ),
        ),
      );
    }
    if (feed.exhausted && endMessage != null) {
      return Padding(
        padding: padding,
        child: Center(
          child: Text(
            endMessage!,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return const SizedBox(height: FuncSpacing.lg);
  }
}

/// Shared first-load state: one centred indicator with an optional
/// translated caption. Pages must not open-code
/// `Center(CircularProgressIndicator())` for a content area's initial load.
class FeedLoading extends StatelessWidget {
  const FeedLoading({super.key, this.label});

  /// Optional translated caption under the indicator; doubles as the
  /// indicator's semantics label.
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(semanticsLabel: label),
          if (label != null) ...[
            const SizedBox(height: FuncSpacing.md),
            Text(label!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// Shared empty/status widget for a feed with no content (or a transient
/// status such as loading/restricted). Renders icon + title, plus an optional
/// refresh button when [onRefresh] is provided.
class FeedEmpty extends StatelessWidget {
  const FeedEmpty({
    super.key,
    this.icon = Icons.inbox_outlined,
    required this.title,
    this.detail,
    this.error,
    this.onRefresh,
    this.retryLabel,
    this.actionLabel,
    this.onAction,
  }) : assert(
         onRefresh == null || retryLabel != null,
         'retryLabel is required when onRefresh is provided',
       ),
       assert(
         onAction == null || actionLabel != null,
         'actionLabel is required when onAction is provided',
       ),
       assert(
         error == null || detail == null,
         'error already supplies the category line and a details disclosure',
       );

  final IconData icon;
  final String title;
  final String? detail;

  /// When set, the detail line is the localized category of this error and
  /// the raw text moves behind an expandable [ErrorDetails] disclosure.
  final Object? error;
  final Future<void> Function()? onRefresh;

  /// Translated label for the refresh button. Required whenever [onRefresh]
  /// is provided — a hardcoded default is how English 'Refresh' leaked into
  /// every locale.
  final String? retryLabel;

  /// Optional secondary action rendered under the refresh button (e.g.
  /// "modify search" on an empty result page).
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: colorScheme.onSurfaceVariant),
          const SizedBox(height: FuncSpacing.md),
          Text(title),
          if (error != null) ...[
            const SizedBox(height: FuncSpacing.sm),
            Text(
              errorCategoryText(context, categorizeError(error!)),
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            ErrorDetails(error: error!),
          ] else if (detail != null) ...[
            const SizedBox(height: FuncSpacing.sm),
            Text(
              detail!,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
          if (onRefresh != null || onAction != null) ...[
            const SizedBox(height: FuncSpacing.md),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (onRefresh != null)
                  OutlinedButton.icon(
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh),
                    label: Text(retryLabel!),
                  ),
                if (onAction != null)
                  OutlinedButton.icon(
                    onPressed: onAction,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(actionLabel!),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Shared feed error state (initial-load failure). Callers keep their own
/// error mapping: [title] and [retryLabel] are already translated, [error]
/// renders as its localized category plus an expandable [ErrorDetails]
/// disclosure — never as raw exception text.
class FeedError extends StatelessWidget {
  const FeedError({
    super.key,
    required this.title,
    required this.onRetry,
    required this.retryLabel,
    this.error,
    this.scrollable = true,
  });

  final String title;
  final Object? error;
  final VoidCallback onRetry;
  final String retryLabel;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off, size: 48),
        const SizedBox(height: FuncSpacing.md),
        Text(title),
        if (error != null) ...[
          const SizedBox(height: FuncSpacing.sm),
          Text(
            errorCategoryText(context, categorizeError(error!)),
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          ErrorDetails(error: error!),
        ],
        const SizedBox(height: FuncSpacing.md),
        FilledButton(onPressed: onRetry, child: Text(retryLabel)),
      ],
    );
    if (!scrollable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.xl),
          child: column,
        ),
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(FuncSpacing.xl),
        child: column,
      ),
    );
  }
}
