import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'follow_models.dart';
import 'follow_repository.dart';
import 'follow_store.dart';

/// UI-facing follow actions: begin in the canonical store, await the API,
/// then commit or fail. Widgets never mutate relationship state directly.
class FollowActions {
  FollowActions(this._ref);

  final Ref _ref;

  Future<void> toggle(int userId) async {
    final store = _ref.read(followStoreProvider.notifier);
    final entry = store.entryOf(userId);
    final operation = (entry?.followed ?? false)
        ? store.beginDelete(userId)
        : store.beginAdd(userId);
    if (operation == null) return;
    await _run(store, operation);
  }

  Future<void> addWithRestrict(int userId, FollowRestrict restrict) async {
    final store = _ref.read(followStoreProvider.notifier);
    final operation = store.beginAdd(userId, restrict: restrict);
    if (operation == null) return;
    await _run(store, operation);
  }

  Future<void> _run(FollowStore store, FollowOperation operation) async {
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
    } on Object catch (error) {
      // Any error, including cancellation, must release the pending spinner
      // and leave the last confirmed value visible.
      store.fail(operation, error);
    }
  }
}

final followActionsProvider = Provider<FollowActions>((ref) {
  return FollowActions(ref);
});
