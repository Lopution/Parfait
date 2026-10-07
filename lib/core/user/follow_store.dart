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
        // C1: the stable account id is the invalidate boundary; a token
        // refresh or profile metadata update keeps the same store valid.
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
        wish: kind == FollowOperationKind.add,
        confirmedRevision: previous?.confirmedRevision,
        status: MutationStatus.pending,
      ),
    };
    return operation;
  }

  /// [BookmarkStore.want] for follows.
  void want(int userId, bool wish) {
    final entry = state[userId];
    if (entry == null || !entry.isUnsettled) return;
    final settled = !entry.isPending && wish == entry.followed;
    state = {...state, userId: entry.copyWith(wish: wish, clearWish: settled)};
  }

  /// [operation] failed on connectivity and now waits in the offline queue.
  void markQueued(FollowOperation operation) {
    final entry = state[operation.userId];
    if (entry?.pending?.envelope != operation.envelope) return;
    state = {
      ...state,
      operation.userId: entry!.copyWith(status: MutationStatus.queued),
    };
  }

  /// A wish the user made meanwhile survives when it differs from the
  /// committed value, for the follow-up request.
  void commit(FollowOperation operation) {
    if (!_owns(operation)) return;
    final added = operation.kind == FollowOperationKind.add;
    final wish = state[operation.userId]?.wish;
    _ledger.finish(operation.envelope);
    state = {
      ...state,
      operation.userId: FollowEntry(
        followed: added,
        restrict: added ? operation.restrict : null,
        wish: wish == added ? null : wish,
        confirmedRevision: operation.revision,
        status: MutationStatus.confirmed,
      ),
    };
    onConfirmed?.call(operation.userId, added);
  }

  /// [BookmarkStore.fail] for follows: rolls back, silently when the user
  /// had already tapped away from the target.
  void fail(FollowOperation operation, Object error) {
    if (!_owns(operation)) return;
    final previous = state[operation.userId];
    final cancelled =
        error is ApiCancelled ||
        operation.cancelToken.isCancelled ||
        previous?.wish != (operation.kind == FollowOperationKind.add);
    if (cancelled) {
      _ledger.discard(operation.envelope, MutationDiscardReason.cancelled);
    } else {
      _ledger.finish(operation.envelope);
    }
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

  /// Settles an offline-replayed intent. When the pending operation that
  /// produced the queued action is still owned, it commits through the
  /// normal ledger path; otherwise the confirmed value merges like a remote
  /// snapshot (process restarted, or a newer pending op owns the entry).
  void settleQueued(
    int userId, {
    required bool followed,
    FollowRestrict? restrict,
  }) {
    final pending = state[userId]?.pending;
    if (pending != null &&
        (pending.kind == FollowOperationKind.add) == followed &&
        _owns(pending)) {
      commit(pending);
      return;
    }
    observeRemote(userId, followed: followed, restrict: restrict);
  }

  /// Merges relationship state from a remote user payload without allowing a
  /// pending or older local confirmation to regress it.
  void observeRemote(
    int userId, {
    required bool? followed,
    FollowRestrict? restrict,
    int? snapshotRevision,
  }) => observeRemoteAll([
    (userId: userId, followed: followed, restrict: restrict),
  ], snapshotRevision: snapshotRevision);

  /// [observeRemote] for a whole payload under one state write — the
  /// BookmarkStore.observeRemoteAll rule: one map copy and one listener
  /// wake per page, none when nothing changes.
  void observeRemoteAll(
    Iterable<FollowSnapshot> snapshots, {
    int? snapshotRevision,
  }) {
    Map<int, FollowEntry>? next;
    for (final snapshot in snapshots) {
      final merged = _mergeRemote(
        (next ?? state)[snapshot.userId],
        snapshot,
        snapshotRevision,
      );
      if (merged != null) (next ??= {...state})[snapshot.userId] = merged;
    }
    if (next != null) state = next;
  }

  /// The entry [snapshot] settles [entry] to — null when the revision gate
  /// rejects it or it would leave the entry as it is.
  static FollowEntry? _mergeRemote(
    FollowEntry? entry,
    FollowSnapshot snapshot,
    int? snapshotRevision,
  ) {
    final (userId: _, :followed, :restrict) = snapshot;
    if (followed == null && restrict == null) return null;
    if (entry?.isUnsettled == true) return null;
    final confirmed = entry?.confirmedRevision;
    if (snapshotRevision != null &&
        confirmed != null &&
        snapshotRevision < confirmed) {
      return null;
    }
    final nextFollowed = followed ?? entry?.followed ?? false;
    final nextRestrict = nextFollowed ? (restrict ?? entry?.restrict) : null;
    if (entry != null &&
        entry.status == MutationStatus.idle &&
        entry.pending == null &&
        entry.error == null &&
        entry.followed == nextFollowed &&
        entry.restrict == nextRestrict) {
      return null;
    }
    return FollowEntry(
      followed: nextFollowed,
      restrict: nextRestrict,
      confirmedRevision: confirmed,
      status: MutationStatus.idle,
    );
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
        : MutationDiscardReason.accountChanged;
    _ledger.cancelAll(reason);
    if (!settleState) return;
    final next = <int, FollowEntry>{...state};
    for (final item in next.entries) {
      if (!item.value.isUnsettled) continue;
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
