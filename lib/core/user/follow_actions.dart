import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../actionqueue/action_bootstrap.dart';
import '../actionqueue/action_models.dart';
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

/// UI-facing follow actions: begin in the canonical store, await the API,
/// then commit or fail. Widgets never mutate relationship state directly.
class _FollowActions {
  _FollowActions(this._ref);

  final Ref _ref;

  /// Follows or unfollows [userId]. Returns what an unfollow removed, for
  /// Undo. Null when nothing was removed (a follow, a suppressed request, a
  /// failure or a queued unfollow) or when the original visibility could
  /// not be read — then there is no Undo: guessing "public" would expose a
  /// private follow.
  Future<RemovedFollow?> toggle(int userId) async {
    final store = _ref.read(followStoreProvider.notifier);
    final entry = store.entryOf(userId);
    if (entry == null || !entry.followed) {
      final operation = store.beginAdd(userId);
      if (operation != null) await _run(store, operation);
      return null;
    }
    final operation = store.beginDelete(userId);
    if (operation == null) return null;
    final restrict = entry.restrict ?? await _fetchRestrict(userId, operation);
    final removed = await _run(store, operation);
    return removed && restrict != null
        ? RemovedFollow(userId: userId, restrict: restrict)
        : null;
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

  Future<void> addWithRestrict(int userId, FollowRestrict restrict) async {
    final store = _ref.read(followStoreProvider.notifier);
    final operation = store.beginAdd(userId, restrict: restrict);
    if (operation == null) return;
    await _run(store, operation);
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
      if (!await _enqueueOffline(operation, error)) {
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
            // Target-scoped key: a pending follow and a later unfollow
            // coalesce to the last intent.
            dedupeKey: 'follow:${op.userId}',
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
