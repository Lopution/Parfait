import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../mutation/mutation_boundary.dart';
import '../mutation/mutation_models.dart';
import '../network/api_error.dart';
import 'follow_models.dart';

/// Canonical, account-scoped follow mutation state.
///
/// User cards and profile headers observe confirmed state here. Each pending
/// operation is fenced by the account, credential and network revision that
/// created it; a late response can therefore never update another account.
class FollowStore extends Notifier<Map<int, FollowEntry>> {
  final MutationLedger _ledger = MutationLedger();
  MutationBoundary? _boundary;
  bool _built = false;
  bool _disposeRegistered = false;

  @override
  Map<int, FollowEntry> build() {
    if (_ledger.isDisposed) {
      _ledger.reopen();
      _disposeRegistered = false;
    }
    ref.watch(
      accountStoreProvider.select((async) {
        final account = async.value;
        return (account?.usableCurrent?.id, account?.credentialRevision ?? 0);
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

  FollowEntry? entryOf(int userId) => state[userId];

  FollowOperation? beginAdd(
    int userId, {
    FollowRestrict restrict = FollowRestrict.public,
  }) => _begin(userId, FollowOperationKind.add, restrict);

  FollowOperation? beginDelete(int userId) =>
      _begin(userId, FollowOperationKind.delete, FollowRestrict.public);

  FollowOperation? _begin(
    int userId,
    FollowOperationKind kind,
    FollowRestrict restrict,
  ) {
    if (userId <= 0) throw const FormatException('userId must be positive');
    final boundary = _requireBoundary();
    final envelope = _ledger.begin(
      boundary: boundary,
      entityType: 'user',
      entityId: '$userId',
      operation: 'follow.${kind.name}',
      ownerId: 'follow:$userId',
    );
    if (envelope == null) return null;
    final previous = state[userId];
    final operation = FollowOperation(
      userId: userId,
      envelope: envelope,
      kind: kind,
      restrict: restrict,
    );
    state = {
      ...state,
      userId: FollowEntry(
        followed: previous?.followed ?? false,
        restrict: previous?.restrict,
        pending: operation,
        confirmedRevision: previous?.confirmedRevision,
        status: MutationStatus.pending,
      ),
    };
    return operation;
  }

  void commit(FollowOperation operation) {
    if (!_owns(operation)) return;
    final added = operation.kind == FollowOperationKind.add;
    _ledger.finish(operation.envelope);
    state = {
      ...state,
      operation.userId: FollowEntry(
        followed: added,
        restrict: added ? operation.restrict : null,
        confirmedRevision: operation.revision,
        status: MutationStatus.confirmed,
      ),
    };
    onConfirmed?.call(operation.userId, added);
  }

  void fail(FollowOperation operation, Object error) {
    if (!_owns(operation)) return;
    final cancelled =
        error is ApiCancelled || operation.cancelToken.isCancelled;
    if (cancelled) {
      _ledger.discard(operation.envelope, MutationDiscardReason.cancelled);
    } else {
      _ledger.finish(operation.envelope);
    }
    final previous = state[operation.userId];
    if (previous?.pending?.envelope != operation.envelope) return;
    state = {
      ...state,
      operation.userId: FollowEntry(
        followed: previous!.followed,
        restrict: previous.restrict,
        error: cancelled ? null : error,
        confirmedRevision: previous.confirmedRevision,
        status: cancelled ? MutationStatus.cancelled : MutationStatus.failed,
      ),
    };
  }

  bool cancel(FollowOperation operation) {
    if (!_owns(operation)) return false;
    _ledger.discard(operation.envelope, MutationDiscardReason.cancelled);
    final previous = state[operation.userId];
    if (previous?.pending?.envelope != operation.envelope) return false;
    state = {
      ...state,
      operation.userId: FollowEntry(
        followed: previous!.followed,
        restrict: previous.restrict,
        confirmedRevision: previous.confirmedRevision,
        status: MutationStatus.cancelled,
      ),
    };
    return true;
  }

  /// Merges relationship state from a remote user payload without allowing a
  /// pending or older local confirmation to regress it.
  void observeRemote(
    int userId, {
    required bool? followed,
    FollowRestrict? restrict,
    int? snapshotRevision,
  }) {
    if (followed == null && restrict == null) return;
    final entry = state[userId];
    if (entry?.isPending == true) return;
    final confirmed = entry?.confirmedRevision;
    if (snapshotRevision != null &&
        confirmed != null &&
        snapshotRevision < confirmed) {
      return;
    }
    final nextFollowed = followed ?? entry?.followed ?? false;
    state = {
      ...state,
      userId: FollowEntry(
        followed: nextFollowed,
        restrict: nextFollowed ? (restrict ?? entry?.restrict) : null,
        confirmedRevision: confirmed,
        status: MutationStatus.idle,
      ),
    };
  }

  bool _owns(FollowOperation operation) {
    if (!_ledger.isActive(operation.envelope)) return false;
    final current = readMutationBoundary(ref);
    _boundary = current;
    final reason = mutationBoundaryReason(operation.envelope, current);
    if (reason != null) {
      _ledger.discard(operation.envelope, reason);
      _setCancelled(operation);
      return false;
    }
    final entry = state[operation.userId];
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
    final reason = _boundary == null || current == null
        ? MutationDiscardReason.accountChanged
        : _boundary!.accountId != current.accountId
        ? MutationDiscardReason.accountChanged
        : _boundary!.credentialRevision != current.credentialRevision
        ? MutationDiscardReason.credentialChanged
        : MutationDiscardReason.networkChanged;
    _ledger.cancelAll(reason);
    if (!settleState) return;
    final next = <int, FollowEntry>{...state};
    for (final item in next.entries) {
      if (!item.value.isPending) continue;
      next[item.key] = FollowEntry(
        followed: item.value.followed,
        restrict: item.value.restrict,
        confirmedRevision: item.value.confirmedRevision,
        status: MutationStatus.cancelled,
      );
    }
    state = next;
  }

  void _setCancelled(FollowOperation operation) {
    final previous = state[operation.userId];
    if (previous?.pending?.envelope != operation.envelope) return;
    state = {
      ...state,
      operation.userId: FollowEntry(
        followed: previous!.followed,
        restrict: previous.restrict,
        confirmedRevision: previous.confirmedRevision,
        status: MutationStatus.cancelled,
      ),
    };
  }

  /// Set by UserStore to mirror confirmed relationship changes without a
  /// provider cycle.
  void Function(int userId, bool followed)? onConfirmed;
}

final followStoreProvider =
    NotifierProvider<FollowStore, Map<int, FollowEntry>>(FollowStore.new);
