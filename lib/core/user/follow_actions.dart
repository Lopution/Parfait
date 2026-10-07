import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../actionqueue/action_bootstrap.dart';
import '../actionqueue/action_models.dart';
import '../mutation/mutation_models.dart';
import '../network/api_error.dart';
import 'follow_models.dart';
import 'follow_repository.dart';
import 'follow_store.dart';

/// What an unfollow removed — enough to follow again with the same
/// visibility.
@immutable
class RemovedFollow {
  const RemovedFollow({required this.userId, required this.restrict});

  final int userId;
  final FollowRestrict restrict;
}

/// The offline queue's coalescing key: a queued follow and a later unfollow
/// replace each other.
String _dedupeKey(int userId) => 'follow:$userId';

/// UI-facing follow actions: begin in the canonical store, await the API,
/// then commit or fail. Widgets never mutate relationship state directly.
class _FollowActions {
  _FollowActions(this._ref);

  final Ref _ref;

  /// Follows or unfollows [userId] — the shown value flips at once and the
  /// server settles one request at a time ([settleToggle]). Returns what an
  /// unfollow removed, for Undo. Null when nothing was removed (a follow, a
  /// failure, a queued unfollow, or a tap that only redirected a request
  /// already under way) or when the original visibility could not be read
  /// — then there is no Undo: guessing "public" would expose a private
  /// follow.
  Future<RemovedFollow?> toggle(int userId) async {
    final store = _ref.read(followStoreProvider.notifier);
    final entry = store.entryOf(userId);
    final wish = !(entry?.shown ?? false);
    if (entry != null && entry.isUnsettled) {
      await _redirect(store, entry, userId, wish);
      return null;
    }
    return _settle(store, userId, wish: wish);
  }

  /// [_BookmarkActions] rule: requests [wish], then follows later taps; a
  /// re-follow puts back [restore] or what the unfollow before it removed.
  Future<RemovedFollow?> _settle(
    FollowStore store,
    int userId, {
    required bool wish,
    RemovedFollow? restore,
  }) async {
    var removed = restore;
    Future<bool> request(bool target) async {
      if (!target) return _unfollow(store, userId, (value) => removed = value);
      final restored = removed;
      removed = null;
      final operation = store.beginAdd(
        userId,
        restrict: restored?.restrict ?? FollowRestrict.public,
      );
      return operation != null && await _run(store, operation);
    }

    final settled = await settleToggle(
      first: () => request(wish),
      request: request,
      nextWish: () => store.entryOf(userId)?.wish,
    );
    return settled ? removed : null;
  }

  /// [_BookmarkActions] rule: a tap in flight records the wish; a tap on a
  /// queued intent drops it.
  Future<void> _redirect(
    FollowStore store,
    FollowEntry entry,
    int userId,
    bool wish,
  ) async {
    final operation = entry.pending;
    if (operation == null || !entry.isQueued) {
      store.want(userId, wish);
      return;
    }
    final dropped = await _ref
        .read(actionQueueProvider)
        .dropPending(
          owner: operation.envelope.accountId,
          dedupeKey: _dedupeKey(userId),
        );
    if (dropped) store.cancel(operation);
  }

  Future<bool> _unfollow(
    FollowStore store,
    int userId,
    void Function(RemovedFollow? removed) onRemoved,
  ) async {
    final known = store.entryOf(userId)?.restrict;
    final operation = store.beginDelete(userId);
    if (operation == null) return false;
    final restrict = known ?? await _fetchRestrict(userId, operation);
    onRemoved(
      restrict == null
          ? null
          : RemovedFollow(userId: userId, restrict: restrict),
    );
    return _run(store, operation);
  }

  /// Reads the follow's visibility from the server before the unfollow;
  /// null when that fails — the unfollow still goes ahead, without Undo.
  Future<FollowRestrict?> _fetchRestrict(
    int userId,
    FollowOperation operation,
  ) async {
    try {
      return await _ref
          .read(followRepositoryProvider)
          .fetchRestrict(userId, cancelToken: operation.cancelToken);
    } on Object {
      return null;
    }
  }

  /// Sheet follow, visibility switch and Undo. An unsettled entry
  /// suppresses the request.
  Future<void> addWithRestrict(int userId, FollowRestrict restrict) async {
    final store = _ref.read(followStoreProvider.notifier);
    if (store.entryOf(userId)?.isUnsettled ?? false) return;
    await _settle(
      store,
      userId,
      wish: true,
      restore: RemovedFollow(userId: userId, restrict: restrict),
    );
  }

  /// True when the server confirmed [operation].
  Future<bool> _run(FollowStore store, FollowOperation operation) async {
    try {
      final repository = _ref.read(followRepositoryProvider);
      switch (operation.kind) {
        case FollowOperationKind.add:
          await repository.add(
            operation.userId,
            restrict: operation.restrict,
            cancelToken: operation.cancelToken,
          );
        case FollowOperationKind.delete:
          await repository.delete(
            operation.userId,
            cancelToken: operation.cancelToken,
          );
      }
      store.commit(operation);
      // A completed mutation is connectivity evidence — piggyback a queue
      // drain so earlier offline intents replay immediately.
      pumpActionQueue(_ref);
      return true;
    } on ApiError catch (error) {
      if (await _enqueueOffline(operation, error)) {
        store.markQueued(operation);
      } else {
        store.fail(operation, error);
      }
    } on Object catch (error) {
      // Any error, including cancellation, must release the pending spinner
      // and leave the last confirmed value visible.
      store.fail(operation, error);
    }
    return false;
  }

  /// Connectivity-class failures persist the intent instead of failing the
  /// entry: the store keeps its pending state and the queued action replays
  /// through the same repository once the queue drains. Returns true when
  /// the intent is durably queued; a store failure falls back to the
  /// visible error path.
  Future<bool> _enqueueOffline(FollowOperation op, ApiError error) async {
    if (!isConnectivityError(error)) return false;
    try {
      await _ref
          .read(actionQueueProvider)
          .enqueue(
            owner: op.envelope.accountId,
            type: op.kind == FollowOperationKind.add
                ? ActionTypes.followAdd
                : ActionTypes.followDelete,
            dedupeKey: _dedupeKey(op.userId),
            payload: {
              'user': op.userId,
              if (op.kind == FollowOperationKind.add)
                'restrict': op.restrict.name,
            },
          );
      return true;
    } on Object {
      return false;
    }
  }
}

final followActionsProvider = Provider<_FollowActions>((ref) {
  return _FollowActions(ref);
});
