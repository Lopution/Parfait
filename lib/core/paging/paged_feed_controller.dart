import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/illust_entity.dart';
import '../entity/illust_store.dart';
import '../network/api_error.dart';
import '../network/pixiv_http_client.dart';
import '../settings/app_settings.dart';
import '../settings/blocked_tags.dart';
import '../settings/local_block_filter.dart';
import '../settings/settings_controller.dart';
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

  /// Fetches and parses one page without committing shared state.
  ///
  /// This is the single required fetch hook (C12): every feed implements its
  /// own transport, cancellation and commit. The former cursor-only
  /// [fetchPage] contract is gone — a subclass must never throw
  /// `UnimplementedError('use fetchPageForContext')` to disown it.
  Future<FeedPage> fetchPageForContext(FeedRequestContext context);

  /// Whether discovery-list filtering (C9) applies to this feed. Feed
  /// subclasses that render discovery content (recommended, ranking, search,
  /// user works) return true and implement [filterPageIds] with the shared
  /// predicate; bookmark/history/detail paths leave this false.
  bool get localFilterEnabled => false;

  /// Applies the C9 predicate to one server page. Only called when
  /// [localFilterEnabled] is true. Entities unavailable in the shared store
  /// are kept (no evidence to hide them).
  List<int> filterPageIds(
    List<int> ids, {
    Map<int, IllustEntity>? incomingIllusts,
  }) {
    final store = ref.read(illustStoreProvider);
    final settings = ref.read(settingsProvider).value;
    if (settings == null) return ids;
    final blockedTags = ref.read(blockedTagsProvider);
    return [
      for (final id in ids)
        if (!_isFilteredId(
          id,
          store,
          settings,
          blockedTags,
          incomingIllusts: incomingIllusts,
        ))
          id,
    ];
  }

  bool _isFilteredId(
    int id,
    IllustStore store,
    AppSettings settings,
    Set<String> blockedTags, {
    Map<int, IllustEntity>? incomingIllusts,
  }) {
    final entity = incomingIllusts?[id] ?? store.get(id);
    if (entity == null) return false;
    return isLocallyBlocked(
      entity,
      blockR18: settings.enableLocalBlockR18,
      blockAI: settings.enableLocalBlockAI,
      blockedTags: blockedTags,
    );
  }

  /// Minimum visible items after filtering. When a server page leaves fewer
  /// visible items, the controller keeps fetching subsequent pages (bounded
  /// by [filterMaxRefillPages]) until the threshold or the server's end.
  int get filterMinVisible => 0;

  /// Hard cap on consecutive refill requests; prevents an unbounded fetch
  /// loop when a high block rate leaves every page short.
  int get filterMaxRefillPages => 3;

  /// Fetches the page and, for filtered discovery feeds, refills from
  /// subsequent pages until [filterMinVisible] is reached or the server is
  /// exhausted. Refill pages share the parent request's cancellation token
  /// and generation but never flip the commit gate's active context: the
  /// caller still commits through the original [context].
  Future<FeedPage> fetchRelevantPage(FeedRequestContext context) async {
    var page = await fetchPageForContext(context);
    if (!localFilterEnabled || filterMinVisible <= 0) return page;
    var visible = filterPageIds(
      page.ids,
      incomingIllusts: page.incomingIllusts,
    );
    // Nothing was filtered out: a short server page is the server's own
    // shape and must not trigger refill (which would change pagination for
    // users who never enable blocking).
    if (visible.length >= page.ids.length) {
      return page;
    }
    if (visible.length >= filterMinVisible) {
      return FeedPage(
        ids: visible,
        nextCursor: page.nextCursor,
        commit: page.commit,
      );
    }
    var nextCursor = page.nextCursor;
    final commits = <FeedPageCommit?>[page.commit];
    for (
      var refill = 1;
      visible.length < filterMinVisible &&
          nextCursor != null &&
          refill <= filterMaxRefillPages;
      refill++
    ) {
      final refillContext = FeedRequestContext(
        feedKey: context.feedKey,
        accountId: context.accountId,
        generation: context.generation,
        page: context.page + refill,
        cursor: nextCursor,
        cancelToken: context.cancelToken,
      );
      try {
        final nextPage = await fetchPageForContext(refillContext);
        if (!_isContextActive(context) || context.isCancelled) break;
        nextCursor = _validatedRefillCursor(nextPage.nextCursor, refillContext);
        visible = _dedupe(
          filterPageIds(
            nextPage.ids,
            incomingIllusts: nextPage.incomingIllusts,
          ),
          visible,
        );
        commits.add(nextPage.commit);
      } on ApiCancelled {
        break;
      } on ApiError {
        // Server ended or a transient refill failure: keep what was already
        // fetched and present normally — never an unbounded retry loop.
        break;
      }
    }
    return FeedPage(
      ids: visible,
      nextCursor: nextCursor,
      commit: (finalContext) {
        for (final commit in commits) {
          commit?.call(finalContext);
        }
      },
    );
  }

  /// Validates a refill page cursor without touching the committed-cursor
  /// ledger; the final cursor recorded by the caller is the last accepted
  /// one. Returns null (stop refilling) when rejected or repeated.
  String? _validatedRefillCursor(
    String? rawCursor,
    FeedRequestContext context,
  ) {
    if (rawCursor == null || rawCursor.isEmpty) return null;
    String? cursor;
    try {
      cursor = validateCursor(rawCursor);
    } on ApiError {
      return null;
    }
    if (cursor == null ||
        cursor == context.cursor ||
        _committedCursors.contains(cursor)) {
      return null;
    }
    return cursor;
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
        return account?.current?.id;
      }),
    );
    // C9 R1.4: a settings change in the filter section must invalidate
    // discovery feeds so the next visit already reflects the new rules.
    ref.watch(
      settingsProvider.select(
        (async) => (
          async.value?.enableLocalBlockR18 ?? false,
          async.value?.enableLocalBlockAI ?? false,
        ),
      ),
    );
    if (localFilterEnabled) {
      ref.watch(blockedTagsProvider);
    }
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
      final page = await fetchRelevantPage(context);
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
      final page = await fetchRelevantPage(context);
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
      final page = await fetchRelevantPage(context);
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
      disposed: _disposed,
      action: () => page.commit?.call(context),
    );
  }

  bool _isContextActive(FeedRequestContext context) {
    return !_disposed && _commitGate.isActive(context, accountId: _accountId);
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

  String? _accountIdFor(FeedRequestContext context) =>
      _disposed ? context.accountId : _accountId;
}
