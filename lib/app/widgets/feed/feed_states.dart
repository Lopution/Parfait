import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/errors/error_category.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/network_restore_signal.dart';
import '../../../core/paging/paged_feed_controller.dart';
import '../../../l10n/context.dart';
import '../../motion/state_fade.dart';
import '../app_top_bar.dart';
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
                FailureReport(
                  action: errorTitle ?? 'load more',
                  error: loadMoreError,
                ),
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
    return _StatusCenter(
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
         'error already supplies the category line',
       );

  final IconData icon;
  final String title;
  final String? detail;

  /// When set, the detail line is the localized category of this error and
  /// the raw text goes to the crash log ([FailureReport]).
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
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusIcon(icon),
        const SizedBox(height: FuncSpacing.lg),
        _StatusTitle(title),
        if (error != null) ...[
          const SizedBox(height: FuncSpacing.sm),
          Text(
            errorCategoryText(context, categorizeError(error!)),
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          FailureReport(action: title, error: error!),
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
    );
    // Always the result of a state change (loading → empty): fade in. An
    // error's details expand, so a short or large-text screen scrolls to
    // the buttons, as FeedError does.
    final content = StateFade.onMount(
      child: _StatusCenter(
        child: error == null ? column : SingleChildScrollView(child: column),
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

/// A filtered feed with nothing to show yet although the server has more
/// ([PagedFeedState.isAllHidden]): it says the loaded works are blocked,
/// muted or filtered out and loads on, a page and its refills per tap,
/// never on its own (user decision 10-28: walking the results unasked
/// could fetch them all).
class FeedAllHidden extends StatelessWidget {
  const FeedAllHidden({
    super.key,
    required this.feed,
    required this.onLoadMore,
  });

  final PagedFeedState feed;

  /// The feed's user-initiated load-more (`retryLoadMore`).
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (feed.showLoadMoreSpinner) {
      return FeedLoading(label: l10n.contentLoading);
    }
    final error = feed.showLoadMoreError ? feed.loadMoreError : null;
    final content = FeedEmpty(
      icon: Icons.visibility_off_outlined,
      title: l10n.feedAllHidden,
      error: error,
      actionLabel: l10n.feedContinueLoading,
      actionIcon: Icons.expand_more,
      onAction: onLoadMore,
    );
    // A failed load the user asked for retries once the network is back.
    return error == null
        ? content
        : RetryOnNetworkRestore(
            error: error,
            onRetry: onLoadMore,
            child: content,
          );
  }
}

/// Shared feed error state (initial-load failure). Callers keep their own
/// error mapping: [title] and [retryLabel] are already translated, [error]
/// renders as its localized category, its raw text recorded by
/// [FailureReport] — never shown.
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
        const _StatusIcon(Icons.cloud_off),
        const SizedBox(height: FuncSpacing.lg),
        _StatusTitle(title),
        if (error != null) ...[
          const SizedBox(height: FuncSpacing.sm),
          Text(
            errorCategoryText(context, categorizeError(error!)),
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          FailureReport(action: title, error: error!),
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
        child: _StatusCenter(
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

/// The icon of an empty or error state, on a disc so it carries the view
/// without a line of explanation (PAGE-20).
class _StatusIcon extends StatelessWidget {
  const _StatusIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        shape: BoxShape.circle,
      ),
      child: Padding(
        padding: const EdgeInsets.all(FuncSpacing.xl),
        child: Icon(icon, size: 40, color: colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _StatusTitle extends StatelessWidget {
  const _StatusTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: Theme.of(context).textTheme.titleSmall,
    textAlign: TextAlign.center,
  );
}

/// Places a status view on the area under the page's toolbar, the bar's
/// extension (tabs, a filter row, a search field) counted in: an empty or
/// failed page shows its status as high whether or not its bar carries
/// tabs, and a first load and the state after it share the spot. The spot
/// is the optical centre, a little above the middle.
class _StatusCenter extends SingleChildRenderObjectWidget {
  const _StatusCenter({required super.child});

  /// The extension under the page's [AppTopBar], read on each layout: a
  /// bar that gains or loses one resizes the body, which lays this out
  /// again, while an unchanged body may never rebuild.
  static double _extensionOf(BuildContext context) {
    final bar = Scaffold.maybeOf(context)?.widget.appBar;
    return bar is AppTopBar ? bar.bottom?.preferredSize.height ?? 0.0 : 0.0;
  }

  @override
  _RenderStatusCenter createRenderObject(BuildContext context) =>
      _RenderStatusCenter(() => _extensionOf(context));

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderStatusCenter renderObject,
  ) => renderObject.extension = () => _extensionOf(context);
}

/// Places its child at the optical centre of its box extended up by the
/// bar's extension, kept inside the box. Without a height to fill (in a
/// scrollable) it is the child over the extension's height of space, as
/// a centred child with that bottom padding would be.
class _RenderStatusCenter extends RenderShiftedBox {
  _RenderStatusCenter(this._extension) : super(null);

  ValueGetter<double> _extension;
  set extension(ValueGetter<double> value) {
    _extension = value;
    markNeedsLayout();
  }

  /// Where the child's top sits in the free space: 0.5 is the middle.
  static const _freeSpaceAbove = 0.4;

  @override
  double computeMinIntrinsicHeight(double width) =>
      (child?.getMinIntrinsicHeight(width) ?? 0) + _extension();

  @override
  double computeMaxIntrinsicHeight(double width) =>
      (child?.getMaxIntrinsicHeight(width) ?? 0) + _extension();

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final childSize = child?.getDryLayout(constraints.loosen()) ?? Size.zero;
    return _sizeFor(constraints, childSize);
  }

  Size _sizeFor(BoxConstraints constraints, Size childSize) =>
      constraints.constrain(
        Size(
          constraints.hasBoundedWidth ? constraints.maxWidth : childSize.width,
          constraints.hasBoundedHeight
              ? constraints.maxHeight
              : childSize.height + _extension(),
        ),
      );

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    size = _sizeFor(constraints, child.size);
    final extension = _extension();
    final top =
        (size.height + extension - child.size.height) * _freeSpaceAbove -
        extension;
    (child.parentData! as BoxParentData).offset = Offset(
      (size.width - child.size.width) / 2,
      top.clamp(0, math.max(0, size.height - child.size.height)),
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

/// Retries a section's failed first load on its own, Shaft's
/// SectionLoader rule: twice, [delays] apart, before the failure stays on
/// screen for the user's retry. A rate limit waits at least as long as the
/// server asked. Only failures that can pass are retried: a 404 or a parse
/// error would fail the same way again.
///
/// Mount it where it outlives the section's loading/error swaps; [failed]
/// turning true is one failure.
class AutoRetry extends StatefulWidget {
  const AutoRetry({
    super.key,
    required this.failed,
    required this.error,
    required this.onRetry,
    required this.child,
  });

  /// Waits before each automatic retry: 1.5 s, then 3 s.
  static const delays = [Duration(milliseconds: 1500), Duration(seconds: 3)];

  final bool failed;
  final Object? error;
  final VoidCallback onRetry;
  final Widget child;

  @override
  State<AutoRetry> createState() => _AutoRetryState();
}

class _AutoRetryState extends State<AutoRetry> {
  var _attempts = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.failed) _onFailure();
  }

  @override
  void didUpdateWidget(AutoRetry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.failed && !oldWidget.failed) _onFailure();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onFailure() {
    final error = widget.error;
    if (_attempts >= AutoRetry.delays.length || !_transient(error)) return;
    var delay = AutoRetry.delays[_attempts++];
    if (error case ApiRateLimited(:final retryAfter?) when retryAfter > delay) {
      delay = retryAfter;
    }
    _timer?.cancel();
    _timer = Timer(delay, () {
      if (mounted && widget.failed) widget.onRetry();
    });
  }

  static bool _transient(Object? error) =>
      error != null &&
      switch (categorizeError(error)) {
        ErrorCategory.network ||
        ErrorCategory.timeout ||
        ErrorCategory.rateLimited ||
        ErrorCategory.server => true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) => widget.child;
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
