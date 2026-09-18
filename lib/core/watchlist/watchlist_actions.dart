/// Watchlist (追更) mutation entry point — toggles series following with
/// the same offline-queue contract as bookmark/follow actions.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../actionqueue/action_bootstrap.dart';
import '../actionqueue/action_models.dart';
import '../network/api_error.dart';
import 'watchlist_models.dart';
import 'watchlist_repository.dart';
import 'watchlist_store.dart';

class _WatchlistActions {
  _WatchlistActions(this._ref);

  final Ref _ref;

  Future<void> toggle(WatchlistKey key) async {
    final store = _ref.read(watchlistStoreProvider.notifier);
    final added = store.entryOf(key)?.added ?? false;
    final operation = added ? store.beginDelete(key) : store.beginAdd(key);
    if (operation == null) return;
    await _run(operation);
  }

  Future<void> _run(WatchlistOp operation) async {
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
    } on ApiError catch (error) {
      if (isConnectivityError(error) && _enqueueOffline(operation)) {
        return;
      }
      store.fail(operation, error);
    } catch (error) {
      store.fail(operation, error);
    }
  }

  bool _enqueueOffline(WatchlistOp operation) {
    try {
      _ref
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
