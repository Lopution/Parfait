import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import 'follow_store.dart';
import 'user_entity.dart';

/// Canonical account-scoped store for all user previews and detail profiles.
///
/// Pages keep only IDs and read entities back from this store. A provider
/// rebuild on account change drops the old map, preventing account A's user
/// data from appearing while account B loads.
class UserStore extends Notifier<Map<int, UserEntity>> {
  @override
  Map<int, UserEntity> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    final follows = ref.watch(followStoreProvider.notifier);
    follows.onConfirmed = (userId, followed) => updateFollow(userId, followed);
    return {};
  }

  UserEntity? get(int userId) => state[userId];

  List<UserEntity> getAll(Iterable<int> ids) => [
    for (final id in ids)
      if (state[id] != null) state[id]!,
  ];

  /// Captures the follow revision before a detail/preview request. The
  /// repository passes it back to [mergeAll] so stale responses cannot clear a
  /// locally confirmed follow.
  int followRevisionNow() =>
      ref.read(followStoreProvider.notifier).revisionNow();

  void mergeAll(Iterable<UserEntity> incoming, {int? followSnapshotRevision}) {
    final follows = ref.read(followStoreProvider.notifier);
    final next = Map<int, UserEntity>.of(state);
    for (final entity in incoming) {
      follows.observeRemote(
        entity.id,
        followed: entity.isFollowed,
        snapshotRevision: followSnapshotRevision,
      );
      final authority = follows.entryOf(entity.id)?.followed;
      final existing = next[entity.id];
      final merged = existing == null ? entity : existing.merge(entity);
      next[entity.id] = authority == null
          ? merged
          : merged.copyWith(isFollowed: authority);
    }
    state = next;
  }

  void updateFollow(int userId, bool followed) {
    final entity = state[userId];
    if (entity == null) return;
    state = {...state, userId: entity.copyWith(isFollowed: followed)};
  }

  void clear() => state = {};
}

final userStoreProvider = NotifierProvider<UserStore, Map<int, UserEntity>>(
  UserStore.new,
);
