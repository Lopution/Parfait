import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/errors/error_category.dart';
import '../../../core/network/network_restore_signal.dart';
import '../../../core/paging/paged_feed_controller.dart';
import '../../../l10n/context.dart';
import '../../motion/state_fade.dart';
import '../errors/error_details.dart';
import '../../theme/func_semantic_tokens.dart';

/// Shared feed-tail widget: load-more spinner, load-more error + retry,
/// "continue" once automatic paging paused, and the exhausted marker.
/// Consumes [PagedFeedState] phase semantics; error and end texts and the
/// retry wiring stay caller-owned. [onRetry] also continues a paused feed
/// (`PagedFeedController.retryLoadMore`).
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
      final retry = onRetry;
      final tail = Center(
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
      return retry == null
          ? tail
          : RetryOnNetworkRestore(
              error: loadMoreError,
              onRetry: retry,
              child: tail,
            );
    }
    if (feed.loadMorePaused && onRetry != null) {
      return Padding(
        padding: padding,
        child: Center(
          child: TextButton.icon(
            key: const Key('feed-continue-loading'),
            onPressed: onRetry,
            icon: const Icon(Icons.expand_more),
            label: Text(context.l10n.feedContinueLoading),
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
    this.actionIcon = Icons.edit_outlined,
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

  /// Offered only where content can still arrive: a live feed that is empty
  /// for now, or a failure ([error] set). Content that is simply not there
  /// — a user without works, an empty history — gets no button (U4).
  final Future<void> Function()? onRefresh;

  /// Translated label for the refresh button: `refresh` for an empty live
  /// feed, `retry` for a failure. Required whenever [onRefresh] is provided
  /// — a hardcoded default is how English 'Refresh' leaked into every
  /// locale.
  final String? retryLabel;

  /// Optional other action (e.g. "modify search" on an empty result page).
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData actionIcon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Always the result of a state change (loading → empty): fade in.
    final content = StateFade.onMount(
      child: Center(
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
                    StateActionButton(label: retryLabel!, onPressed: onRefresh),
                  if (onAction != null)
                    StateActionButton(
                      label: actionLabel!,
                      icon: actionIcon,
                      onPressed: onAction,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
    final refresh = onRefresh;
    // A failure shown as a status (a profile that failed to load) retries
    // like FeedError does.
    return error == null || refresh == null
        ? content
        : RetryOnNetworkRestore(
            error: error,
            onRetry: () => unawaited(refresh()),
            child: content,
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
        Icon(
          Icons.cloud_off,
          size: 48,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
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
        StateActionButton(label: retryLabel, onPressed: onRetry),
      ],
    );
    // Always the result of a state change (loading → error): fade in.
    return RetryOnNetworkRestore(
      error: error,
      onRetry: onRetry,
      child: StateFade.onMount(
        child: Center(
          child: scrollable
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(FuncSpacing.xl),
                  child: column,
                )
              : Padding(
                  padding: const EdgeInsets.all(FuncSpacing.xl),
                  child: column,
                ),
        ),
      ),
    );
  }
}

/// The button of the empty, error and status states (H1): one tonal button
/// with a leading icon, the same for a retry, a refresh and any other
/// action they offer.
class StateActionButton extends StatelessWidget {
  const StateActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.refresh,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: onPressed,
    icon: Icon(icon),
    label: Text(label),
  );
}

/// Runs [onRetry] once each time the network comes back while [child] — an
/// error state — is on screen (HCI 9). Only failures a missing connection
/// explains retry: a 404 or a parse error would fail the same way again.
/// A retry that fails again just shows the error, until the next restore.
class RetryOnNetworkRestore extends ConsumerWidget {
  const RetryOnNetworkRestore({
    super.key,
    required this.error,
    required this.onRetry,
    required this.child,
  });

  /// The failure on screen; null when the caller does not know it.
  final Object? error;
  final VoidCallback onRetry;
  final Widget child;

  static bool _connectionFailure(Object? error) =>
      error == null ||
      switch (categorizeError(error)) {
        ErrorCategory.network || ErrorCategory.timeout => true,
        _ => false,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(networkRestoreSignalProvider, (_, _) {
      if (_connectionFailure(error)) onRetry();
    });
    return child;
  }
}
