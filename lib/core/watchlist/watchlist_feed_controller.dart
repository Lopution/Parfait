import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import 'watchlist_models.dart';
import 'watchlist_repository.dart';

@immutable
class WatchlistFeedState {
  const WatchlistFeedState({
    required this.entries,
    this.nextUrl,
    this.loadingMore = false,
    this.loadMoreError,
  });

  final List<WatchlistSeriesEntry> entries;
  final String? nextUrl;
  final bool loadingMore;
  final Object? loadMoreError;

  bool get hasMore => nextUrl != null;

  WatchlistFeedState copyWith({
    List<WatchlistSeriesEntry>? entries,
    String? nextUrl,
    bool? loadingMore,
    Object? loadMoreError,
    bool clearNextUrl = false,
    bool clearLoadMoreError = false,
  }) {
    return WatchlistFeedState(
      entries: entries ?? this.entries,
      nextUrl: clearNextUrl ? null : (nextUrl ?? this.nextUrl),
      loadingMore: loadingMore ?? this.loadingMore,
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
    );
  }
}

/// Paged watchlist rows — entries carry their own display payload, so this
/// is a hand-rolled paged list (same shape as the bookmark-tags feed), not
/// a PagedFeedController.
class _WatchlistFeedController extends AsyncNotifier<WatchlistFeedState> {
  _WatchlistFeedController(this.type);

  final WatchlistType type;

  @override
  Future<WatchlistFeedState> build() async {
    // Watchlists are account-scoped data: an account switch re-resolves
    // the list rather than leaking rows across accounts.
    final accountId = await ref.watch(
      accountStoreProvider.selectAsync((state) => state.usableCurrent?.id),
    );
    if (accountId == null) {
      return const WatchlistFeedState(entries: []);
    }
    return _fetch(null);
  }

  Future<void> loadMore() async {
    final current = state.value;
    final nextUrl = current?.nextUrl;
    if (current == null || nextUrl == null || current.loadingMore) return;
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await _fetch(nextUrl);
      state = AsyncData(
        current.copyWith(
          entries: [...current.entries, ...page.entries],
          nextUrl: page.nextUrl,
          loadingMore: false,
          clearLoadMoreError: true,
        ),
      );
    } on Object catch (error) {
      state = AsyncData(
        current.copyWith(loadingMore: false, loadMoreError: error),
      );
    }
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _fetch(null));
  }

  Future<WatchlistFeedState> _fetch(String? cursor) async {
    final page = await ref
        .read(watchlistRepositoryProvider)
        .fetchWatchlist(type, cursor: cursor);
    return WatchlistFeedState(entries: page.entries, nextUrl: page.nextUrl);
  }
}

final watchlistFeedProvider =
    AsyncNotifierProvider.family<
      _WatchlistFeedController,
      WatchlistFeedState,
      WatchlistType
    >(_WatchlistFeedController.new);
