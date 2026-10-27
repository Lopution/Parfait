import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../errors/no_retry.dart';
import 'watchlist_models.dart';
import 'watchlist_repository.dart';
import 'watchlist_store.dart';

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
    // the list rather than leaking rows across accounts. This build's ref,
    // taken before any await: afterwards `ref` is the next build's.
    final owner = ref;
    final accountId = await ref.watch(
      accountStoreProvider.selectAsync((state) => state.usableCurrent?.id),
    );
    if (accountId == null || !owner.mounted) {
      return const WatchlistFeedState(entries: []);
    }
    return _fetch(null, AccountClaim(owner));
  }

  Future<void> loadMore() async {
    final current = state.value;
    final nextUrl = current?.nextUrl;
    if (current == null || nextUrl == null || current.loadingMore) return;
    final claim = AccountClaim(ref);
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await _fetch(nextUrl, claim);
      // [current] is the previous account's list after a switch.
      if (!claim.holds) return;
      state = AsyncData(
        current.copyWith(
          entries: [...current.entries, ...page.entries],
          nextUrl: page.nextUrl,
          // The last page carries no cursor; keeping the old one reloads it.
          clearNextUrl: page.nextUrl == null,
          loadingMore: false,
          clearLoadMoreError: true,
        ),
      );
    } on Object catch (error) {
      if (!claim.holds) return;
      state = AsyncData(
        current.copyWith(loadingMore: false, loadMoreError: error),
      );
    }
  }

  Future<void> refresh() async {
    final claim = AccountClaim(ref);
    state = const AsyncLoading();
    final next = await AsyncValue.guard(() => _fetch(null, claim));
    if (claim.holds) state = next;
  }

  /// One page for the build or method that took [claim]; the store is
  /// seeded only while [claim] holds.
  Future<WatchlistFeedState> _fetch(String? cursor, AccountClaim claim) async {
    final page = await ref
        .read(watchlistRepositoryProvider)
        .fetchWatchlist(type, cursor: cursor);
    if (!claim.holds) {
      return WatchlistFeedState(entries: page.entries, nextUrl: page.nextUrl);
    }
    // The feed is itself remote truth: every listed series is followed.
    // Seeding the store lets `watchlistActionsProvider.toggle` resolve the
    // delete direction — otherwise an unobserved row would re-add.
    final store = claim.ref.read(watchlistStoreProvider.notifier);
    for (final entry in page.entries) {
      store.observeRemote(entry.key, added: true);
    }
    return WatchlistFeedState(entries: page.entries, nextUrl: page.nextUrl);
  }
}

final watchlistFeedProvider =
    AsyncNotifierProvider.family<
      _WatchlistFeedController,
      WatchlistFeedState,
      WatchlistType
    >(_WatchlistFeedController.new, retry: noRetry);
