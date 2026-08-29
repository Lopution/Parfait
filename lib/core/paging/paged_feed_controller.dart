import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../network/api_error.dart';
import '../network/pixiv_http_client.dart';
import 'feed_request_context.dart';

export 'feed_request_context.dart';

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

  static const _unset = Object();

  PagedFeedState copyWith({
    List<int>? ids,
    FeedPhase? initialPhase,
    FeedPhase? refreshPhase,
    FeedPhase? loadMorePhase,
    Object? initialError = _unset,
    Object? loadMoreError = _unset,
    bool? exhausted,
  }) {
    return PagedFeedState(
      ids: ids ?? this.ids,
      initialPhase: initialPhase ?? this.initialPhase,
      refreshPhase: refreshPhase ?? this.refreshPhase,
      loadMorePhase: loadMorePhase ?? this.loadMorePhase,
      initialError: identical(initialError, _unset)
          ? this.initialError
          : initialError as ApiError?,
      loadMoreError: identical(loadMoreError, _unset)
          ? this.loadMoreError
          : loadMoreError as ApiError?,
      exhausted: exhausted ?? this.exhausted,
    );
  }
}

/// Contract for one page of results.
typedef PageFetcher<T> =
    Future<({List<int> ids, String? nextCursor})> Function(String? cursor);

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
  /// Stable identity of the feed family and all of its selectors.
  ///
  /// Feed families should override this with a key that includes their mode,
  /// query, filter, or profile selector. The key is copied into every request
  /// context and never inferred from a late response.
  String get feedKey => runtimeType.toString();

  /// Fetches one page. [cursor] is `null` for the first page.
  Future<({List<int> ids, String? nextCursor})> fetchPage(String? cursor);

  /// Cancellable fetch hook. Existing feeds can keep using [fetchPage]; feeds
  /// backed by a transport that supports cancellation override this method.
  Future<({List<int> ids, String? nextCursor})> fetchPageCancellable(
    String? cursor,
    CancelToken cancelToken,
  ) => fetchPage(cursor);

  /// Fetches and parses a page without committing shared state.
  ///
  /// Feed implementations that own shared entities override this hook and
  /// return a [FeedPage] whose [FeedPage.commit] performs the merge. The base
  /// adapter keeps existing ID-only feeds source compatible while making the
  /// commit boundary explicit for migrated feeds.
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final page = await fetchPageCancellable(
      context.cursor,
      context.cancelToken,
    );
    return FeedPage(ids: page.ids, nextCursor: page.nextCursor);
  }

  /// Validates a server-provided cursor (e.g. the next_url allowlist).
  /// Throw to reject; the feed surfaces the error instead of requesting.
  String? validateCursor(String? rawCursor) => rawCursor;

  String? _nextCursor;
  int _page = 0;
  static const _maxCommittedCursors = 128;
  final List<String> _committedCursors = <String>[];
  bool _disposed = false;
  bool _disposeCallbackRegistered = false;
  final FeedCommitGate _commitGate = FeedCommitGate();

  /// Current valid cursor (visible for subclass/tests).
  String? get nextCursor => _nextCursor;

  /// Bounded telemetry for responses discarded at the commit boundary.
  List<FeedDiscardEvent> get discardEvents => _commitGate.discardEvents;

  @override
  Future<PagedFeedState> build() async {
    // Depend on the complete account boundary so a family instance cannot
    // retain a cursor/entity list across account or credential changes. This
    // is intentionally a synchronous watch: authenticated repositories may
    // await account hydration themselves, but this feed build must not await a
    // dependency that can invalidate the build while it is suspended.
    ref.watch(
      accountStoreProvider.select((async) {
        final account = async.asData?.value;
        return (account?.current?.id, account?.credentialRevision ?? 0);
      }),
    );
    // Do not await AccountStore here. Public feeds may be rendered before
    // account hydration completes, while authenticated repositories already
    // await the same account future before sending. The watched boundary
    // invalidates this request if hydration changes the snapshot before its
    // page can commit.
    _disposed = false;
    _nextCursor = null;
    _page = 0;
    _committedCursors.clear();
    if (!_disposeCallbackRegistered) {
      _disposeCallbackRegistered = true;
      ref.onDispose(() {
        _disposed = true;
        _commitGate.dispose();
      });
    }
    final generation = _commitGate.beginGeneration();
    final context = _beginRequest(
      generation: generation,
      page: 1,
      cursor: null,
    );
    try {
      final page = await fetchPageForContext(context);
      final nextCursor = _validateCursor(page.nextCursor, context);
      if (!_commitPage(context, page)) {
        return const PagedFeedState(initialPhase: FeedPhase.idle);
      }
      _recordCursor(nextCursor);
      _nextCursor = nextCursor;
      _page = 1;
      return PagedFeedState(
        ids: _dedupe(page.ids, const []),
        initialPhase: FeedPhase.idle,
        exhausted: _nextCursor == null,
      );
    } on ApiCancelled {
      _discardContext(context);
      return const PagedFeedState(initialPhase: FeedPhase.idle);
    } on ApiError catch (error) {
      if (!_isContextActive(context)) {
        _discardContext(context);
        return const PagedFeedState(initialPhase: FeedPhase.idle);
      }
      return PagedFeedState(initialPhase: FeedPhase.error, initialError: error);
    } finally {
      _commitGate.finish(context);
    }
  }

  /// Reloads page one (pull-to-refresh).
  Future<void> refresh() async {
    final current = state.requireValue;
    if (current.showRefreshSpinner || current.showInitialSpinner) return;
    state = AsyncData(
      current.copyWith(
        refreshPhase: FeedPhase.loading,
        loadMorePhase: FeedPhase.idle,
        loadMoreError: null,
      ),
    );
    final generation = _commitGate.beginGeneration();
    _page = 0;
    _committedCursors.clear();
    final context = _beginRequest(
      generation: generation,
      page: 1,
      cursor: null,
    );
    try {
      final page = await fetchPageForContext(context);
      final nextCursor = _validateCursor(page.nextCursor, context);
      if (!_commitPage(context, page)) {
        _restoreRefreshPhaseIfCurrent(context);
        return;
      }
      _recordCursor(nextCursor);
      _nextCursor = nextCursor;
      _page = 1;
      final ids = _dedupe(page.ids, const []);
      state = AsyncData(
        PagedFeedState(
          ids: ids,
          initialPhase: FeedPhase.idle,
          refreshPhase: FeedPhase.idle,
          exhausted: _nextCursor == null,
        ),
      );
    } on ApiCancelled {
      if (_isContextActive(context)) {
        _commitGate.discard(
          context,
          accountId: _accountIdFor(context),
          credentialRevision: _credentialRevisionFor(context),
          reason: FeedDiscardReason.cancelled,
        );
        state = AsyncData(current.copyWith(refreshPhase: FeedPhase.idle));
      } else {
        _discardContext(context);
        _restoreRefreshPhaseIfCurrent(context);
      }
    } on ApiError catch (error) {
      if (!_isContextActive(context)) {
        _discardContext(context);
        _restoreRefreshPhaseIfCurrent(context);
        return;
      }
      // Refresh failure keeps existing content and cursor; the spinner stops
      // and the phase signals the failure to the UI.
      _stateError = error;
      state = AsyncData(
        current.copyWith(
          refreshPhase: FeedPhase.error,
          loadMorePhase: FeedPhase.idle,
          loadMoreError: null,
        ),
      );
    } finally {
      _commitGate.finish(context);
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
        current.showRefreshSpinner ||
        current.showInitialSpinner ||
        current.showInitialError) {
      return;
    }
    if (_nextCursor == null) {
      state = AsyncData(current.copyWith(exhausted: true));
      return;
    }
    state = AsyncData(
      current.copyWith(loadMorePhase: FeedPhase.loading, loadMoreError: null),
    );
    final cursor = _nextCursor;
    final context = _beginRequest(
      generation: _commitGate.generation,
      page: _page + 1,
      cursor: cursor,
    );
    try {
      final page = await fetchPageForContext(context);
      final nextCursor = _validateCursor(page.nextCursor, context);
      if (!_commitPage(context, page)) {
        _restoreLoadMorePhaseIfCurrent(context);
        return;
      }
      _recordCursor(nextCursor);
      _nextCursor = nextCursor;
      _page = context.page;
      final merged = _dedupe(page.ids, current.ids);
      state = AsyncData(
        PagedFeedState(
          ids: merged,
          initialPhase: FeedPhase.idle,
          loadMorePhase: FeedPhase.idle,
          exhausted: _nextCursor == null,
        ),
      );
    } on ApiCancelled {
      if (_isContextActive(context)) {
        _commitGate.discard(
          context,
          accountId: _accountIdFor(context),
          credentialRevision: _credentialRevisionFor(context),
          reason: FeedDiscardReason.cancelled,
        );
        state = AsyncData(current.copyWith(loadMorePhase: FeedPhase.idle));
      } else {
        _discardContext(context);
        _restoreLoadMorePhaseIfCurrent(context);
      }
    } on ApiError catch (error) {
      if (!_isContextActive(context)) {
        _discardContext(context);
        _restoreLoadMorePhaseIfCurrent(context);
        return;
      }
      state = AsyncData(
        current.copyWith(loadMorePhase: FeedPhase.error, loadMoreError: error),
      );
    } finally {
      _commitGate.finish(context);
    }
  }

  /// Retry the initial load.
  Future<void> retryInitial() async {
    state = const AsyncLoading<PagedFeedState>();
    state = await AsyncValue.guard(() => build());
  }

  /// Retry the failed load-more.
  Future<void> retryLoadMore() => loadMore();

  /// Cancels the active request and returns a loading phase to idle without
  /// discarding already loaded IDs or the last valid cursor.
  void cancel() {
    _commitGate.cancelActive();
    final current = state.asData?.value;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        initialPhase: current.showInitialSpinner
            ? FeedPhase.idle
            : current.initialPhase,
        refreshPhase: current.showRefreshSpinner
            ? FeedPhase.idle
            : current.refreshPhase,
        loadMorePhase: current.showLoadMoreSpinner
            ? FeedPhase.idle
            : current.loadMorePhase,
      ),
    );
  }

  FeedRequestContext _beginRequest({
    required int generation,
    required int page,
    required String? cursor,
  }) {
    return _commitGate.beginRequest(
      feedKey: feedKey,
      accountId: _accountId,
      credentialRevision: _credentialRevision,
      generation: generation,
      page: page,
      cursor: cursor,
      cancelToken: CancelToken(),
    );
  }

  bool _commitPage(FeedRequestContext context, FeedPage page) {
    return _commitGate.commit(
      context,
      accountId: _accountIdFor(context),
      credentialRevision: _credentialRevisionFor(context),
      disposed: _disposed,
      action: () => page.commit?.call(context),
    );
  }

  bool _isContextActive(FeedRequestContext context) {
    return !_disposed &&
        _commitGate.isActive(
          context,
          accountId: _accountId,
          credentialRevision: _credentialRevision,
        );
  }

  void _restoreRefreshPhaseIfCurrent(FeedRequestContext context) {
    if (_disposed || !_commitGate.isCurrent(context)) return;
    final current = state.asData?.value;
    if (current == null || !current.showRefreshSpinner) return;
    state = AsyncData(current.copyWith(refreshPhase: FeedPhase.idle));
  }

  void _restoreLoadMorePhaseIfCurrent(FeedRequestContext context) {
    if (_disposed || !_commitGate.isCurrent(context)) return;
    final current = state.asData?.value;
    if (current == null || !current.showLoadMoreSpinner) return;
    state = AsyncData(current.copyWith(loadMorePhase: FeedPhase.idle));
  }

  void _discardContext(FeedRequestContext context) {
    _commitGate.discard(
      context,
      accountId: _accountIdFor(context),
      credentialRevision: _credentialRevisionFor(context),
      disposed: _disposed,
    );
  }

  String? _validateCursor(String? rawCursor, FeedRequestContext context) {
    if (rawCursor == null || rawCursor.isEmpty) return null;
    final cursor = validateCursor(rawCursor);
    if (cursor == null) {
      // validateCursor returning null for a non-empty cursor is a reject.
      throw const ApiParseError('cursor rejected by allowlist');
    }
    if (cursor == context.cursor || _committedCursors.contains(cursor)) {
      throw const ApiParseError('cursor repeated by page response');
    }
    return cursor;
  }

  void _recordCursor(String? cursor) {
    if (cursor == null || _committedCursors.contains(cursor)) return;
    if (_committedCursors.length == _maxCommittedCursors) {
      _committedCursors.removeAt(0);
    }
    _committedCursors.add(cursor);
  }

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

  String? get _accountId =>
      ref.read(accountStoreProvider).asData?.value.current?.id;

  int get _credentialRevision =>
      ref.read(accountStoreProvider).asData?.value.credentialRevision ?? 0;

  String? _accountIdFor(FeedRequestContext context) =>
      _disposed ? context.accountId : _accountId;

  int _credentialRevisionFor(FeedRequestContext context) =>
      _disposed ? context.credentialRevision : _credentialRevision;
}
