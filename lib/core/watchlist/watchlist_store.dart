/// Account-scoped confirmed/pending watchlist (追更) state and mutation
/// ownership — same contract as [BookmarkStore]/[FollowStore].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mutation/account_scoped_mutation_store.dart';
import '../mutation/mutation_models.dart';
import '../network/api_error.dart';
import '../series/series_store.dart';
import '../settings/shared_preferences.dart';
import 'watchlist_models.dart';

/// Canonical, account-scoped watchlist mutation store.
///
/// Series pages and the watchlist tab observe confirmed state here. Each
/// pending operation is fenced by the account boundary that created it;
/// connectivity failures are queued by the action layer and replayed
/// through [settleQueued].
class WatchlistStore extends Notifier<Map<WatchlistKey, WatchlistEntry>>
    with AccountScopedMutationStore<Map<WatchlistKey, WatchlistEntry>> {
  @override
  Map<WatchlistKey, WatchlistEntry> build() {
    initAccountBoundary();
    return {};
  }

  WatchlistEntry? entryOf(WatchlistKey key) => state[key];

  /// Confirmed watch state for a series, or null when nothing was
  /// observed locally yet.
  bool? addedOf(WatchlistKey key) => state[key]?.added;

  WatchlistOp? beginAdd(WatchlistKey key) => _begin(key, WatchlistOpKind.add);

  WatchlistOp? beginDelete(WatchlistKey key) =>
      _begin(key, WatchlistOpKind.delete);

  WatchlistOp? _begin(WatchlistKey key, WatchlistOpKind kind) {
    final boundary = requireBoundary();
    final envelope = ledger.begin(
      boundary: boundary,
      entityType: 'watchlist:${key.type.apiValue}',
      entityId: '${key.type.apiValue}:${key.seriesId}',
      operation: 'watchlist.${kind.name}',
      ownerId: 'watchlist:${key.type.apiValue}:${key.seriesId}',
    );
    if (envelope == null) return null;
    final previous = state[key];
    final operation = WatchlistOp(key: key, envelope: envelope, kind: kind);
    state = {
      ...state,
      key: WatchlistEntry(
        added: previous?.added ?? false,
        pending: operation,
        wish: kind == WatchlistOpKind.add,
        confirmedRevision: previous?.confirmedRevision,
        status: MutationStatus.pending,
      ),
    };
    return operation;
  }

  /// [BookmarkStore.want] for the watchlist.
  void want(WatchlistKey key, bool wish) {
    final entry = state[key];
    if (entry == null || !entry.isUnsettled) return;
    final settled = !entry.isPending && wish == entry.added;
    state = {...state, key: entry.copyWith(wish: wish, clearWish: settled)};
  }

  /// [operation] failed on connectivity and now waits in the offline queue.
  void markQueued(WatchlistOp operation) {
    final entry = state[operation.key];
    if (entry?.pending?.envelope != operation.envelope) return;
    state = {
      ...state,
      operation.key: entry!.copyWith(status: MutationStatus.queued),
    };
  }

  /// A wish the user made meanwhile survives when it differs from the
  /// committed value, for the follow-up request.
  void commit(WatchlistOp operation) {
    if (!_owns(operation)) return;
    final added = operation.kind == WatchlistOpKind.add;
    final wish = state[operation.key]?.wish;
    ledger.finish(operation.envelope);
    state = {
      ...state,
      operation.key: WatchlistEntry(
        added: added,
        wish: wish == added ? null : wish,
        confirmedRevision: operation.revision,
        status: MutationStatus.confirmed,
      ),
    };
    _mirror(operation.key, added);
  }

  /// [BookmarkStore.fail] for the watchlist: rolls back, silently when the
  /// user had already tapped away from the target.
  void fail(WatchlistOp operation, Object error) {
    if (!_owns(operation)) return;
    final previous = state[operation.key];
    final cancelled =
        error is ApiCancelled ||
        operation.isCancelled ||
        previous?.wish != (operation.kind == WatchlistOpKind.add);
    if (cancelled) {
      ledger.discard(operation.envelope, MutationDiscardReason.cancelled);
    } else {
      ledger.finish(operation.envelope);
    }
    if (previous?.pending?.envelope != operation.envelope) return;
    state = {
      ...state,
      operation.key: WatchlistEntry(
        added: previous!.added,
        error: cancelled ? null : error,
        confirmedRevision: previous.confirmedRevision,
        status: cancelled ? MutationStatus.cancelled : MutationStatus.failed,
      ),
    };
  }

  /// Takes back a queued [operation] whose offline intent was dropped; the
  /// confirmed value shows again.
  bool cancel(WatchlistOp operation) {
    if (!_owns(operation)) return false;
    ledger.discard(operation.envelope, MutationDiscardReason.cancelled);
    _setCancelled(operation);
    return true;
  }

  /// Settles an offline-replayed intent — identical contract to
  /// [BookmarkStore.settleQueued].
  void settleQueued(WatchlistKey key, {required bool added}) {
    final pending = state[key]?.pending;
    if (pending != null &&
        (pending.kind == WatchlistOpKind.add) == added &&
        _owns(pending)) {
      commit(pending);
      return;
    }
    observeRemote(key, added: added);
  }

  /// Rolls back a queued offline intent whose background replay failed
  /// permanently so the entry leaves `MutationStatus.queued` and accepts
  /// subsequent taps and remote snapshots.
  void failQueued(
    WatchlistKey key, {
    required bool added,
    required Object error,
  }) {
    final entry = state[key];
    final pending = entry?.pending;
    if (entry == null ||
        !entry.isQueued ||
        pending == null ||
        (pending.kind == WatchlistOpKind.add) != added) {
      return;
    }
    fail(pending, error);
  }

  /// Merges a remote watch state (series-detail `watchlist_added`) without
  /// letting a pending or older local confirmation regress.
  void observeRemote(
    WatchlistKey key, {
    required bool? added,
    int? snapshotRevision,
  }) {
    if (added == null) return;
    final entry = state[key];
    if (entry?.isUnsettled == true) return;
    final confirmed = entry?.confirmedRevision;
    if (snapshotRevision != null &&
        confirmed != null &&
        snapshotRevision < confirmed) {
      return;
    }
    state = {
      ...state,
      key: WatchlistEntry(
        added: added,
        confirmedRevision: confirmed,
        status: MutationStatus.idle,
      ),
    };
    _mirror(key, added);
  }

  /// Keeps the illust-series store's `watchlistAdded` flag in step with
  /// every confirmed watch change (online commit, queued replay, remote
  /// observe). Novel series have no canonical store — the series bar reads
  /// this store's entry ahead of the detail flag.
  void _mirror(WatchlistKey key, bool added) {
    if (key.type != WatchlistType.manga) return;
    ref
        .read(illustSeriesStoreProvider.notifier)
        .markWatchlist(key.seriesId, added);
  }

  bool _owns(WatchlistOp operation) => ownsMutation(
    operation.envelope,
    isPendingOwner: () =>
        state[operation.key]?.pending?.envelope == operation.envelope,
    onBoundaryCancelled: () => _setCancelled(operation),
  );

  @override
  void settlePendingOnBoundaryInvalidated() {
    final next = <WatchlistKey, WatchlistEntry>{...state};
    for (final item in next.entries) {
      if (!item.value.isUnsettled) continue;
      next[item.key] = WatchlistEntry(
        added: item.value.added,
        confirmedRevision: item.value.confirmedRevision,
        status: MutationStatus.cancelled,
      );
    }
    state = next;
  }

  void _setCancelled(WatchlistOp operation) {
    final previous = state[operation.key];
    if (previous?.pending?.envelope != operation.envelope) return;
    state = {
      ...state,
      operation.key: WatchlistEntry(
        added: previous!.added,
        confirmedRevision: previous.confirmedRevision,
        status: MutationStatus.cancelled,
      ),
    };
  }
}

final watchlistStoreProvider =
    NotifierProvider<WatchlistStore, Map<WatchlistKey, WatchlistEntry>>(
      WatchlistStore.new,
    );

/// Local "already seen" cursor for the new-content badge: the newest
/// `latest_content_id` the user opened on this device, per account, series
/// type and series id. A series never opened reads as unseen.
class WatchlistReadCursor {
  WatchlistReadCursor(this._preferences);

  final SharedPreferencesAsync _preferences;

  static String _key(String accountId, WatchlistKey key) =>
      'watchlist.read_cursor.$accountId.${key.type.apiValue}.${key.seriesId}';

  /// The latest content id the user has opened locally; null = never seen.
  Future<int?> read(String accountId, WatchlistKey key) async {
    final value = await _preferences.getInt(_key(accountId, key));
    return value == null || value <= 0 ? null : value;
  }

  /// Marks the series as seen up to [latestContentId] — writes only move
  /// the cursor forward so reopening an older work never revives a badge.
  Future<void> markSeen(
    String accountId,
    WatchlistKey key,
    int latestContentId,
  ) async {
    final current = await read(accountId, key);
    if (current != null && current >= latestContentId) return;
    await _preferences.setInt(_key(accountId, key), latestContentId);
  }
}

final watchlistReadCursorProvider = Provider<WatchlistReadCursor>((ref) {
  return WatchlistReadCursor(ref.watch(sharedPreferencesProvider));
});
