/// Watchlist (追更) mutation entry point — toggles series following with
/// the same offline-queue contract as bookmark/follow actions.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../actionqueue/action_bootstrap.dart';
import '../actionqueue/action_models.dart';
import '../mutation/mutation_models.dart';
import '../network/api_error.dart';
import 'watchlist_models.dart';
import 'watchlist_repository.dart';
import 'watchlist_store.dart';

class _WatchlistActions {
  _WatchlistActions(this._ref);

  final Ref _ref;

  /// Flips the shown value at once and settles on the server one request
  /// at a time — the [_BookmarkActions.toggle] rules, without Undo.
  Future<void> toggle(WatchlistKey key) async {
    final store = _ref.read(watchlistStoreProvider.notifier);
    final entry = store.entryOf(key);
    final wish = !(entry?.shown ?? false);
    if (entry != null && entry.isUnsettled) {
      final operation = entry.pending;
      if (operation == null || !entry.isQueued) {
        store.want(key, wish);
        return;
      }
      final dropped = await _ref
          .read(actionQueueProvider)
          .dropPending(owner: operation.accountId, dedupeKey: key.dedupeKey);
      if (dropped) store.cancel(operation);
      return;
    }
    Future<bool> request(bool target) async {
      final operation = target ? store.beginAdd(key) : store.beginDelete(key);
      return operation != null && await _run(operation);
    }

    await settleToggle(
      first: () => request(wish),
      request: request,
      nextWish: () => store.entryOf(key)?.wish,
    );
  }

  /// True when the server confirmed [operation].
  Future<bool> _run(WatchlistOp operation) async {
    final store = _ref.read(watchlistStoreProvider.notifier);
    final repository = _ref.read(watchlistRepositoryProvider);
    try {
      await switch (operation.kind) {
        WatchlistOpKind.add => repository.add(
          operation.key,
          cancelToken: operation.cancelToken,
        ),
        WatchlistOpKind.delete => repository.delete(
          operation.key,
          cancelToken: operation.cancelToken,
        ),
      };
      store.commit(operation);
      // A completed call is connectivity evidence — replay anything that
      // was queued while offline.
      pumpActionQueue(_ref);
      return true;
    } on ApiError catch (error) {
      if (isConnectivityError(error) && await _enqueueOffline(operation)) {
        store.markQueued(operation);
      } else {
        store.fail(operation, error);
      }
    } catch (error) {
      store.fail(operation, error);
    }
    return false;
  }

  /// True when the intent is durably queued; a queue failure falls back to
  /// the visible error path.
  Future<bool> _enqueueOffline(WatchlistOp operation) async {
    try {
      await _ref
          .read(actionQueueProvider)
          .enqueue(
            owner: operation.accountId,
            type: switch (operation.kind) {
              WatchlistOpKind.add => ActionTypes.watchlistAdd,
              WatchlistOpKind.delete => ActionTypes.watchlistDelete,
            },
            dedupeKey: operation.key.dedupeKey,
            payload: {
              'seriesType': operation.key.type.apiValue,
              'seriesId': operation.key.seriesId,
            },
          );
      return true;
    } on Object {
      return false;
    }
  }
}

final watchlistActionsProvider = Provider<_WatchlistActions>((ref) {
  return _WatchlistActions(ref);
});
