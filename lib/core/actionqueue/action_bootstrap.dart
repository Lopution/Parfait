/// Riverpod wiring for the offline action queue: the store/queue providers,
/// the replay handler registry, and the pump triggers that drive drains —
/// startup, foreground resume, and every successful mutation (see §3 of the
/// task design; deliberately no connectivity plugin).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../bookmark/bookmark_models.dart';
import '../bookmark/bookmark_repository.dart';
import '../bookmark/bookmark_store.dart';
import '../paging/feed_snapshot_store.dart';
import '../user/follow_models.dart';
import '../user/follow_repository.dart';
import '../user/follow_store.dart';
import 'action_models.dart';
import 'action_queue.dart';
import 'action_store.dart';

final actionStoreProvider = Provider<ActionStore>((ref) {
  return SqliteActionStore(database: ref.watch(feedDatabaseProvider));
});

final actionQueueProvider = Provider<ActionQueue>((ref) {
  final queue = ActionQueue(store: ref.watch(actionStoreProvider));
  _registerMutationHandlers(ref, queue);
  return queue;
});

/// Pump on (re)build: at startup and whenever the signed-in account
/// changes, the current owner's ready rows replay once. The app root also
/// watches this provider so it stays alive for the session.
final actionQueuePumpProvider = Provider<void>((ref) {
  ref.watch(actionQueueProvider);
  final accountId = ref.watch(
    accountStoreProvider.select((async) => async.value?.usableCurrent?.id),
  );
  if (accountId == null) return;
  unawaited(ref.read(actionQueueProvider).drain(accountId));
});

/// Pumps the current owner's queue on demand — called after every
/// successful mutation (a completed call is evidence of connectivity).
/// The foreground-resume hook drains through [drainActionQueue] instead.
void pumpActionQueue(Ref ref) {
  final accountId = ref.read(accountStoreProvider).value?.usableCurrent?.id;
  if (accountId == null) return;
  unawaited(ref.read(actionQueueProvider).drain(accountId));
}

/// Replays call the same repositories as online mutations; a success then
/// settles the still-pending store entry through the normal commit path or,
/// when the pending op is gone (process restarted, newer intent pending),
/// merges the confirmed value via the remote-observe path.
void _registerMutationHandlers(Ref ref, ActionQueue queue) {
  queue.registerHandler(ActionTypes.bookmarkAdd, (action) async {
    final payload = action.decodePayload();
    final key = _bookmarkKey(payload);
    final restrict = payload['restrict'] == 'private'
        ? BookmarkRestrict.private
        : BookmarkRestrict.public;
    final tags = [
      for (final tag in payload['tags'] as List? ?? const []) tag as String,
    ];
    final repository = ref.read(bookmarkRepositoryProvider);
    if (key.type == BookmarkEntityType.novel) {
      await repository.addNovel(key.id, restrict, tags: tags);
    } else {
      await repository.addIllust(key.id, restrict, tags: tags);
    }
    ref
        .read(bookmarkStoreProvider.notifier)
        .settleQueued(key, bookmarked: true, restrict: restrict, tags: tags);
  });
  queue.registerHandler(ActionTypes.bookmarkDelete, (action) async {
    final key = _bookmarkKey(action.decodePayload());
    final repository = ref.read(bookmarkRepositoryProvider);
    if (key.type == BookmarkEntityType.novel) {
      await repository.deleteNovel(key.id);
    } else {
      await repository.deleteIllust(key.id);
    }
    ref
        .read(bookmarkStoreProvider.notifier)
        .settleQueued(key, bookmarked: false);
  });
  queue.registerHandler(ActionTypes.followAdd, (action) async {
    final payload = action.decodePayload();
    final userId = payload['user']! as int;
    final restrict = payload['restrict'] == 'private'
        ? FollowRestrict.private
        : FollowRestrict.public;
    await ref.read(followRepositoryProvider).add(userId, restrict: restrict);
    ref
        .read(followStoreProvider.notifier)
        .settleQueued(userId, followed: true, restrict: restrict);
  });
  queue.registerHandler(ActionTypes.followDelete, (action) async {
    final userId = action.decodePayload()['user']! as int;
    await ref.read(followRepositoryProvider).delete(userId);
    ref
        .read(followStoreProvider.notifier)
        .settleQueued(userId, followed: false);
  });
}

BookmarkKey _bookmarkKey(Map<String, Object?> payload) {
  final entity = payload['entity'];
  final id = payload['id'];
  if (id is! int) {
    throw const FormatException('action payload is missing a work id');
  }
  return BookmarkKey(
    entity == 'novel' ? BookmarkEntityType.novel : BookmarkEntityType.illust,
    id,
  );
}
