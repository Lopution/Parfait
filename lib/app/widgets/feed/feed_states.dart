import 'package:material_ui/material_ui.dart';

import '../../../core/paging/paged_feed_controller.dart';

/// Shared feed-tail widget: load-more spinner, load-more error + retry and
/// the exhausted marker. Consumes [PagedFeedState] phase semantics; text and
/// retry wiring stay caller-owned (i18n accessors live at the call site).
class FeedTail extends StatelessWidget {
  const FeedTail({
    super.key,
    required this.feed,
    this.onRetry,
    this.errorTitle,
    this.retryLabel = 'Retry',
    this.endMessage,
    this.padding = const EdgeInsets.all(16),
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
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (feed.showLoadMoreError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (errorTitle != null) Text(errorTitle!),
              Text(
                '${feed.loadMoreError}',
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
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
    return const SizedBox(height: 16);
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
            const SizedBox(height: 12),
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
    this.onRefresh,
    this.retryLabel = 'Refresh',
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Future<void> Function()? onRefresh;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(title),
          if (detail != null) ...[
            const SizedBox(height: 8),
            Text(
              detail!,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
          if (onRefresh != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: Text(retryLabel),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shared feed error state (initial-load failure). Callers keep their own
/// error mapping: [title] and [retryLabel] are already translated, [error]
/// is rendered as its string form below the title.
class FeedError extends StatelessWidget {
  const FeedError({
    super.key,
    required this.title,
    required this.onRetry,
    this.retryLabel = 'Retry',
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
        const SizedBox(height: 12),
        Text(title),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(
            '$error',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 12),
        FilledButton(onPressed: onRetry, child: Text(retryLabel)),
      ],
    );
    if (!scrollable) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(24), child: column),
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: column,
      ),
    );
  }
}
