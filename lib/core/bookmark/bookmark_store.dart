import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../mutation/mutation_boundary.dart';
import '../mutation/mutation_models.dart';
import '../network/api_error.dart';
import 'bookmark_models.dart';

/// Canonical, account-scoped bookmark mutation store.
///
/// Every operation carries the account/credential/network boundary at which
/// it was created. The shared ledger owns dedupe, cancellation and stale
/// response telemetry; this store owns only confirmed bookmark state and the
/// UI-visible lifecycle.
class BookmarkStore extends Notifier<Map<BookmarkKey, BookmarkEntry>> {
  final MutationLedger _ledger = MutationLedger();
  MutationBoundary? _boundary;
  bool _built = false;
  bool _disposeRegistered = false;

  @override
  Map<BookmarkKey, BookmarkEntry> build() {
    // Riverpod may rebuild a Notifier after an async dependency transitions
    // from loading to data while retaining the Notifier instance.  A ledger
    // disposed by the previous provider lifecycle must not make the new
    // authenticated boundary permanently reject every operation.
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

  BookmarkEntry? entryOf(BookmarkKey key) => state[key];

  BookmarkOp? beginAdd(BookmarkKey key, BookmarkRestrict restrict) =>
      _begin(key, BookmarkOpKind.add, restrict);

  BookmarkOp? beginDelete(BookmarkKey key) =>
      _begin(key, BookmarkOpKind.delete, BookmarkRestrict.public);

  BookmarkOp? _begin(
    BookmarkKey key,
    BookmarkOpKind kind,
    BookmarkRestrict restrict,
  ) {
    final boundary = _requireBoundary();
    final envelope = _ledger.begin(
      boundary: boundary,
      entityType: key.type.name,
      entityId: '${key.type.name}:${key.id}',
      operation: 'bookmark.${kind.name}',
      ownerId: 'bookmark:${key.type.name}:${key.id}',
    );
    if (envelope == null) return null;
    final previous = state[key];
    final operation = BookmarkOp(
      key: key,
      envelope: envelope,
      kind: kind,
      restrict: restrict,
    );
    state = {
      ...state,
      key: BookmarkEntry(
        bookmarked: previous?.bookmarked ?? false,
        restrict: previous?.restrict,
        pending: operation,
        status: MutationStatus.pending,
      ),
    };
    return operation;
  }

  /// Confirms only the still-owned operation. A late result from a
  /// superseded, switched, refreshed or disposed owner cannot update state.
  void commit(BookmarkOp operation) {
    if (!_owns(operation)) return;
    final added = operation.kind == BookmarkOpKind.add;
    _ledger.finish(operation.envelope);
    state = {
      ...state,
      operation.key: BookmarkEntry(
        bookmarked: added,
        restrict: added ? operation.restrict : null,
        confirmedRevision: operation.revision,
        status: MutationStatus.confirmed,
      ),
    };
    onConfirmed?.call(operation.key, added);
  }

  /// Ends the operation with a visible failure/cancellation while retaining
  /// the last confirmed bookmark value.
  void fail(BookmarkOp operation, Object error) {
    if (!_owns(operation)) return;
    final cancelled = error is ApiCancelled || operation.isCancelled;
    if (cancelled) {
      _ledger.discard(operation.envelope, MutationDiscardReason.cancelled);
    } else {
      _ledger.finish(operation.envelope);
    }
    final previous = state[operation.key];
    if (previous == null || previous.pending?.envelope != operation.envelope) {
      return;
    }
    state = {
      ...state,
      operation.key: BookmarkEntry(
        bookmarked: previous.bookmarked,
        restrict: previous.restrict,
        error: cancelled ? null : error,
        confirmedRevision: previous.confirmedRevision,
        status: cancelled ? MutationStatus.cancelled : MutationStatus.failed,
      ),
    };
  }

  /// Explicitly cancels a pending operation owned by a page/lifecycle.
  bool cancel(BookmarkOp operation) {
    if (!_owns(operation)) return false;
    _ledger.discard(operation.envelope, MutationDiscardReason.cancelled);
    final previous = state[operation.key];
    if (previous?.pending?.envelope != operation.envelope) return false;
    state = {
      ...state,
      operation.key: BookmarkEntry(
        bookmarked: previous!.bookmarked,
        restrict: previous.restrict,
        confirmedRevision: previous.confirmedRevision,
        status: MutationStatus.cancelled,
      ),
    };
    return true;
  }

  /// Merges a remote bookmark snapshot. Pending/local-confirmed state is
  /// protected by the same revision boundary used by the request owner.
  void observeRemote(
    BookmarkKey key, {
    bool? bookmarked,
    BookmarkRestrict? restrict,
    int? snapshotRevision,
  }) {
    if (bookmarked == null && restrict == null) return;
    final entry = state[key];
    if (entry != null) {
      if (entry.isPending) return;
      final confirmed = entry.confirmedRevision;
      if (snapshotRevision != null &&
          confirmed != null &&
          snapshotRevision < confirmed) {
        return;
      }
    }
    state = {
      ...state,
      key: BookmarkEntry(
        bookmarked: bookmarked ?? entry?.bookmarked ?? false,
        restrict: restrict ?? entry?.restrict,
        confirmedRevision: entry?.confirmedRevision,
        status: MutationStatus.idle,
      ),
    };
  }

  bool _owns(BookmarkOp operation) {
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
    final reason = _boundary == null || current == null
        ? MutationDiscardReason.accountChanged
        : _boundary!.accountId != current.accountId
        ? MutationDiscardReason.accountChanged
        : MutationDiscardReason.credentialChanged;
    _ledger.cancelAll(reason);
    if (!settleState) return;
    final next = <BookmarkKey, BookmarkEntry>{...state};
    for (final item in next.entries) {
      if (!item.value.isPending) continue;
      next[item.key] = BookmarkEntry(
        bookmarked: item.value.bookmarked,
        restrict: item.value.restrict,
        confirmedRevision: item.value.confirmedRevision,
        status: MutationStatus.cancelled,
      );
    }
    state = next;
  }

  void _setCancelled(BookmarkOp operation) {
    final previous = state[operation.key];
    if (previous?.pending?.envelope != operation.envelope) return;
    state = {
      ...state,
      operation.key: BookmarkEntry(
        bookmarked: previous!.bookmarked,
        restrict: previous.restrict,
        confirmedRevision: previous.confirmedRevision,
        status: MutationStatus.cancelled,
      ),
    };
  }

  /// Set by illustStoreProvider so confirmed changes mirror into the shared
  /// entity map without a provider cycle.
  void Function(BookmarkKey key, bool bookmarked)? onConfirmed;
}

final bookmarkStoreProvider =
    NotifierProvider<BookmarkStore, Map<BookmarkKey, BookmarkEntry>>(
      BookmarkStore.new,
    );
