/// Riverpod wiring for the offline action queue: the store/queue providers,
/// the replay handler registry, and the pump triggers that drive drains —
/// startup, account switch, foreground resume, network restore (the
/// existing connectivity listener's [networkRestoreSignalProvider]) and
/// every successful mutation. The queue's own wake timers cover the rest.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../bookmark/bookmark_models.dart';
import '../bookmark/bookmark_repository.dart';
import '../bookmark/bookmark_store.dart';
import '../log.dart';
import '../network/network_restore_signal.dart';
import '../paging/feed_snapshot_store.dart';
import '../user/follow_models.dart';
import '../user/follow_repository.dart';
import '../user/follow_store.dart';
import '../watchlist/watchlist_models.dart';
import '../watchlist/watchlist_repository.dart';
import '../watchlist/watchlist_store.dart';
import 'action_models.dart';
import 'action_queue.dart';
import 'action_store.dart';

final actionStoreProvider = Provider<ActionStore>((ref) {
  return SqliteActionStore(database: ref.watch(feedDatabaseProvider));
});

final actionQueueProvider = Provider<ActionQueue>((ref) {
  final queue = ActionQueue(store: ref.watch(actionStoreProvider));
  ref.onDispose(queue.dispose);
  _registerMutationHandlers(ref, queue);
  return queue;
});

/// Drains the current account's queue whenever an account becomes current
/// (startup included) and again on a network restore, without waiting out
/// the cooldown. The account being left is parked so its wake never
/// replays under the next account. Everything hangs off `ref.listen`: the
/// app root only reads this provider once, and a provider nobody listens
/// to is never rebuilt when a watched value changes.
final actionQueuePumpProvider = Provider<void>((ref) {
  final queue = ref.watch(actionQueueProvider);
  String? current;
  ref.onDispose(() {
    final owner = current;
    if (owner != null) queue.park(owner);
  });
  ref.listen(networkRestoreSignalProvider, (_, _) {
    final owner = current;
    if (owner == null) return;
    log('action queue: network restored, retrying now');
    unawaited(queue.retryNow(owner));
  });
  ref.listen(
    accountStoreProvider.select((async) => async.value?.usableCurrent?.id),
    (_, next) {
      final previous = current;
      if (next == previous) return;
      if (previous != null) queue.park(previous);
      current = next;
      if (next != null) unawaited(queue.drain(next));
    },
    fireImmediately: true,
  );
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
    if (!_ownerIsCurrent(ref, action)) return;
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
    if (!_ownerIsCurrent(ref, action)) return;
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
    if (!_ownerIsCurrent(ref, action)) return;
    ref
        .read(followStoreProvider.notifier)
        .settleQueued(userId, followed: true, restrict: restrict);
  });
  queue.registerHandler(ActionTypes.followDelete, (action) async {
    final userId = action.decodePayload()['user']! as int;
    await ref.read(followRepositoryProvider).delete(userId);
    if (!_ownerIsCurrent(ref, action)) return;
    ref
        .read(followStoreProvider.notifier)
        .settleQueued(userId, followed: false);
  });
  queue.registerHandler(ActionTypes.watchlistAdd, (action) async {
    final key = _watchlistKey(action.decodePayload());
    await ref.read(watchlistRepositoryProvider).add(key);
    if (!_ownerIsCurrent(ref, action)) return;
    ref.read(watchlistStoreProvider.notifier).settleQueued(key, added: true);
  });
  queue.registerHandler(ActionTypes.watchlistDelete, (action) async {
    final key = _watchlistKey(action.decodePayload());
    await ref.read(watchlistRepositoryProvider).delete(key);
    if (!_ownerIsCurrent(ref, action)) return;
    ref.read(watchlistStoreProvider.notifier).settleQueued(key, added: false);
  });
}

/// The stores hold the current account's state: a replay that finished
/// after its owner was left settles nothing there. The server applied it,
/// and the owner's stores reload when it is current again.
bool _ownerIsCurrent(Ref ref, StoredAction action) =>
    ref.read(accountStoreProvider).value?.usableCurrent?.id == action.owner;

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

WatchlistKey _watchlistKey(Map<String, Object?> payload) {
  final id = payload['seriesId'];
  if (id is! int) {
    throw const FormatException('action payload is missing a series id');
  }
  return WatchlistKey(WatchlistType.fromApiValue(payload['seriesType']), id);
}
