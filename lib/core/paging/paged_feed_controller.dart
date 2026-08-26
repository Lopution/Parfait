import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_error.dart';

/// Independent states for the three load phases of a paginated feed.
enum FeedPhase { idle, loading, error }

/// Snapshot of a paged feed's UI state.
///
/// `ids` reference entities in the shared [IllustStore]; this state never
/// duplicates entity payloads.
class PagedFeedState {
  const PagedFeedState({
    this.ids = const [],
    this.initialPhase = FeedPhase.loading,
    this.refreshPhase = FeedPhase.idle,
    this.loadMorePhase = FeedPhase.idle,
    this.initialError,
    this.loadMoreError,
    this.exhausted = false,
  });

  final List<int> ids;
  final FeedPhase initialPhase;
  final FeedPhase refreshPhase;
  final FeedPhase loadMorePhase;

  /// Error of the very first load (page renders an error + retry screen).
  final ApiError? initialError;

  /// Error of the most recent load-more attempt (banner + retry at the tail).
  final ApiError? loadMoreError;

  /// True when the server has no further pages.
  final bool exhausted;

  bool get showInitialSpinner => initialPhase == FeedPhase.loading;

  bool get showInitialError => initialPhase == FeedPhase.error;

  bool get showLoadMoreSpinner => loadMorePhase == FeedPhase.loading;

  bool get showLoadMoreError => loadMorePhase == FeedPhase.error;

  bool get showRefreshSpinner => refreshPhase == FeedPhase.loading;

  bool get isEmptyAndReady =>
      initialPhase == FeedPhase.idle && ids.isEmpty && !showInitialError;

  PagedFeedState copyWith({
    List<int>? ids,
    FeedPhase? initialPhase,
    FeedPhase? refreshPhase,
    FeedPhase? loadMorePhase,
    ApiError? initialError,
    ApiError? loadMoreError,
    bool? exhausted,
  }) {
    return PagedFeedState(
      ids: ids ?? this.ids,
      initialPhase: initialPhase ?? this.initialPhase,
      refreshPhase: refreshPhase ?? this.refreshPhase,
      loadMorePhase: loadMorePhase ?? this.loadMorePhase,
      initialError: initialError,
      loadMoreError: loadMoreError,
      exhausted: exhausted ?? this.exhausted,
    );
  }
}

/// Contract for one page of results.
typedef PageFetcher<T> = Future<({List<int> ids, String? nextCursor})>
    Function(String? cursor);

/// Base controller for ID-based paginated feeds.
///
/// - initial load: spinner -> data | error (retry re-runs initial).
/// - refresh: re-fetches page one; existing content stays visible on
///   failure (refreshPhase surfaces the failure), success resets the cursor
///   and de-duplicates.
/// - load more: appends with cross-page ID de-duplication; errors surface as
///   loadMoreError without touching existing content; exhausted stops fetches.
/// - every next cursor goes through [validateCursor] before being stored.
abstract class PagedFeedController extends AsyncNotifier<PagedFeedState> {
  /// Fetches one page. [cursor] is `null` for the first page.
  Future<({List<int> ids, String? nextCursor})> fetchPage(String? cursor);

  /// Validates a server-provided cursor (e.g. the next_url allowlist).
  /// Throw to reject; the feed surfaces the error instead of requesting.
  String? validateCursor(String? rawCursor) => rawCursor;

  String? _nextCursor;

  /// Current valid cursor (visible for subclass/tests).
  String? get nextCursor => _nextCursor;

  @override
  Future<PagedFeedState> build() async {
    _nextCursor = null;
    try {
      final page = await fetchPage(null);
      final cursor = validateCursor(page.nextCursor);
      if (page.nextCursor != null && cursor == null && page.nextCursor!.isNotEmpty) {
        // validateCursor returning null for a non-null cursor is a reject.
        throw const ApiParseError('cursor rejected by allowlist');
      }
      _nextCursor = page.nextCursor == null ? null : cursor;
      return PagedFeedState(
        ids: _dedupe(page.ids, const []),
        initialPhase: FeedPhase.idle,
        exhausted: _nextCursor == null,
      );
    } on ApiError catch (error) {
      return PagedFeedState(initialPhase: FeedPhase.error, initialError: error);
    }
  }

  /// Reloads page one (pull-to-refresh).
  Future<void> refresh() async {
    final current = state.requireValue;
    if (current.showRefreshSpinner) return;
    state = AsyncData(current.copyWith(refreshPhase: FeedPhase.loading));
    try {
      final page = await fetchPage(null);
      final nextCursor = validateCursor(page.nextCursor);
      if (page.nextCursor != null && page.nextCursor!.isNotEmpty && nextCursor == null) {
        throw const ApiParseError('cursor rejected by allowlist');
      }
      _nextCursor = page.nextCursor == null ? null : nextCursor;
      final ids = _dedupe(page.ids, const []);
      state = AsyncData(PagedFeedState(
        ids: ids,
        initialPhase: FeedPhase.idle,
        refreshPhase: FeedPhase.idle,
        exhausted: _nextCursor == null,
      ));
    } on ApiError catch (error) {
      // Refresh failure keeps existing content and cursor; the spinner stops
      // and the phase signals the failure to the UI.
      _stateError = error;
      state = AsyncData(
        current.copyWith(refreshPhase: FeedPhase.error),
      );
    }
  }

  ApiError? _stateError;

  /// The last refresh error, if any (UI may show a transient banner).
  ApiError? consumeRefreshError() {
    final error = _stateError;
    _stateError = null;
    return error;
  }

  /// Loads the next page; no-op while loading or exhausted.
  Future<void> loadMore() async {
    final current = state.requireValue;
    if (current.exhausted ||
        current.showLoadMoreSpinner ||
        current.showInitialSpinner ||
        current.showInitialError) {
      return;
    }
    if (_nextCursor == null) {
      state = AsyncData(current.copyWith(exhausted: true));
      return;
    }
    state = AsyncData(current.copyWith(
      loadMorePhase: FeedPhase.loading,
      loadMoreError: null,
    ));
    try {
      final page = await fetchPage(_nextCursor);
      final cursor = validateCursor(page.nextCursor);
      if (page.nextCursor != null && page.nextCursor!.isNotEmpty && cursor == null) {
        throw const ApiParseError('cursor rejected by allowlist');
      }
      _nextCursor = page.nextCursor == null ? null : cursor;
      final merged = _dedupe(page.ids, current.ids);
      state = AsyncData(PagedFeedState(
        ids: merged,
        initialPhase: FeedPhase.idle,
        loadMorePhase: FeedPhase.idle,
        exhausted: _nextCursor == null,
      ));
    } on ApiError catch (error) {
      state = AsyncData(current.copyWith(
        loadMorePhase: FeedPhase.error,
        loadMoreError: error,
      ));
    }
  }

  /// Retry the initial load.
  Future<void> retryInitial() async {
    state = const AsyncLoading<PagedFeedState>();
    state = await AsyncValue.guard(() => build());
  }

  /// Retry the failed load-more.
  Future<void> retryLoadMore() => loadMore();

  List<int> _dedupe(List<int> incoming, List<int> existing) {
    final seen = existing.toSet();
    final result = List<int>.of(existing);
    for (final id in incoming) {
      if (seen.add(id)) {
        result.add(id);
      }
    }
    return result;
  }
}
