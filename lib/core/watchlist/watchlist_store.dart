/// Account-scoped confirmed/pending watchlist (追更) state and mutation
/// ownership — same contract as [BookmarkStore]/[FollowStore].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_store.dart';
import '../mutation/mutation_boundary.dart';
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
class WatchlistStore extends Notifier<Map<WatchlistKey, WatchlistEntry>> {
  final MutationLedger _ledger = MutationLedger();
  MutationBoundary? _boundary;
  bool _built = false;
  bool _disposeRegistered = false;

  @override
  Map<WatchlistKey, WatchlistEntry> build() {
    if (_ledger.isDisposed) {
      _ledger.reopen();
      _disposeRegistered = false;
    }
    ref.watch(
      accountStoreProvider.select((async) {
        final account = async.value;
        return account?.usableCurrent?.id;
      }),
    );
    final current = readMutationBoundary(ref);
    if (_boundary != null && !sameMutationBoundary(_boundary, current)) {
      _invalidateBoundary(current, settleState: false);
    }
    _boundary = current;
    if (!_disposeRegistered) {
      _disposeRegistered = true;
      ref.onDispose(() {
        _ledger.dispose();
        _built = false;
      });
    }
    _built = true;
    return {};
  }

  int revisionNow() => _ledger.revisionNow;

  List<MutationDiscardEvent> get discardEvents => _ledger.discardEvents;

  WatchlistEntry? entryOf(WatchlistKey key) => state[key];

  /// Confirmed watch state for a series, or null when nothing was
  /// observed locally yet.
  bool? addedOf(WatchlistKey key) => state[key]?.added;

  WatchlistOp? beginAdd(WatchlistKey key) => _begin(key, WatchlistOpKind.add);

  WatchlistOp? beginDelete(WatchlistKey key) =>
      _begin(key, WatchlistOpKind.delete);

  WatchlistOp? _begin(WatchlistKey key, WatchlistOpKind kind) {
    final boundary = _requireBoundary();
    final envelope = _ledger.begin(
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
        confirmedRevision: previous?.confirmedRevision,
        status: MutationStatus.pending,
      ),
    };
    return operation;
  }

  void commit(WatchlistOp operation) {
    if (!_owns(operation)) return;
    final added = operation.kind == WatchlistOpKind.add;
    _ledger.finish(operation.envelope);
    state = {
      ...state,
      operation.key: WatchlistEntry(
        added: added,
        confirmedRevision: operation.revision,
        status: MutationStatus.confirmed,
      ),
    };
    _mirror(operation.key, added);
  }

  void fail(WatchlistOp operation, Object error) {
    if (!_owns(operation)) return;
    final cancelled = error is ApiCancelled || operation.isCancelled;
    if (cancelled) {
      _ledger.discard(operation.envelope, MutationDiscardReason.cancelled);
    } else {
      _ledger.finish(operation.envelope);
    }
    final previous = state[operation.key];
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

  /// Merges a remote watch state (series-detail `watchlist_added`) without
  /// letting a pending or older local confirmation regress.
  void observeRemote(
    WatchlistKey key, {
    required bool? added,
    int? snapshotRevision,
  }) {
    if (added == null) return;
    final entry = state[key];
    if (entry?.isPending == true) return;
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

  bool _owns(WatchlistOp operation) {
    if (!_ledger.isActive(operation.envelope)) return false;
    final current = readMutationBoundary(ref);
    _boundary = current;
    final reason = mutationBoundaryReason(operation.envelope, current);
    if (reason != null) {
      _ledger.discard(operation.envelope, reason);
      _setCancelled(operation);
      return false;
    }
    final entry = state[operation.key];
    if (entry?.pending?.envelope != operation.envelope) {
      _ledger.discard(operation.envelope, MutationDiscardReason.stale);
      return false;
    }
    return true;
  }

  MutationBoundary _requireBoundary() {
    final current = readMutationBoundary(ref);
    if (current == null) {
      throw const ApiUnauthorized('no signed-in account');
    }
    if (_boundary != null && !sameMutationBoundary(_boundary, current)) {
      _invalidateBoundary(current, settleState: _built);
    }
    _boundary = current;
    return current;
  }

  void _invalidateBoundary(
    MutationBoundary? current, {
    required bool settleState,
  }) {
    _ledger.cancelAll(MutationDiscardReason.accountChanged);
    if (!settleState) return;
    final next = <WatchlistKey, WatchlistEntry>{...state};
    for (final item in next.entries) {
      if (!item.value.isPending) continue;
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
