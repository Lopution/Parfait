import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import 'follow_models.dart';

/// Canonical, account-scoped follow mutation state.
///
/// User cards, profile headers and later Comment/Live surfaces all subscribe
/// to this store. It follows the same non-optimistic revision protocol as the
/// bookmark store: duplicate operations are suppressed, late completions are
/// ignored, and failures restore the confirmed value.
class FollowStore extends Notifier<Map<int, FollowEntry>> {
  int _revision = 0;

  /// Set by [userStoreProvider] so a confirmed relationship is mirrored into
  /// the shared UserEntity without creating a provider cycle.
  void Function(int userId, bool followed)? onConfirmed;

  @override
  Map<int, FollowEntry> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    _revision = 0;
    return {};
  }

  int revisionNow() => _revision;

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
    final entry = state[userId];
    if (entry != null && entry.isPending) return null;
    final operation = FollowOperation(
      userId: userId,
      revision: ++_revision,
      kind: kind,
      restrict: restrict,
    );
    state = {
      ...state,
      userId: FollowEntry(
        followed: entry?.followed ?? false,
        restrict: entry?.restrict,
        pending: operation,
        confirmedRevision: entry?.confirmedRevision,
      ),
    };
    return operation;
  }

  void commit(FollowOperation operation) {
    final entry = state[operation.userId];
    if (entry?.pending?.revision != operation.revision) return;
    final added = operation.kind == FollowOperationKind.add;
    state = {
      ...state,
      operation.userId: FollowEntry(
        followed: added,
        restrict: added ? operation.restrict : null,
        confirmedRevision: operation.revision,
      ),
    };
    onConfirmed?.call(operation.userId, added);
  }

  void fail(FollowOperation operation, Object error) {
    final entry = state[operation.userId];
    if (entry?.pending?.revision != operation.revision) return;
    state = {
      ...state,
      operation.userId: entry!.copyWith(
        pending: null,
        error: error,
        clearPending: true,
      ),
    };
  }

  /// Merges a relationship value returned by a user detail/preview request.
  /// A pending local operation and an older fetch snapshot never regress the
  /// visible relationship.
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
      ),
    };
  }
}

final followStoreProvider =
    NotifierProvider<FollowStore, Map<int, FollowEntry>>(FollowStore.new);
