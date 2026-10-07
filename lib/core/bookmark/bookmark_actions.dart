import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../actionqueue/action_bootstrap.dart';
import '../actionqueue/action_models.dart';
import '../mutation/mutation_models.dart';
import '../network/api_error.dart';
import 'bookmark_models.dart';
import 'bookmark_repository.dart';
import 'bookmark_store.dart';

/// What an unbookmark removed — enough to put it back exactly, visibility
/// and tags included.
@immutable
class RemovedBookmark {
  const RemovedBookmark({
    required this.key,
    required this.restrict,
    this.tags = const [],
  });

  final BookmarkKey key;
  final BookmarkRestrict restrict;
  final List<String> tags;
}

/// The offline queue's coalescing key for [key]: a queued add and a later
/// delete replace each other.
String _dedupeKey(BookmarkKey key) => 'bookmark:${key.type.name}:${key.id}';

/// UI-facing bookmark actions: store begin → repository call → commit/fail.
///
/// Widgets never call the repository or mutate the store directly (design
/// §Architecture); suppressions surface as a null op and simply do nothing.
class _BookmarkActions {
  _BookmarkActions(this._ref);

  final Ref _ref;

  /// Short-press behaviour (beta56 changeBookmarkState): flips the shown
  /// value at once — not bookmarked → public add, bookmarked → delete — and
  /// settles on the server one request at a time ([settleToggle]).
  ///
  /// Returns what a delete removed, for Undo. Null when nothing was removed
  /// (an add, a failure, a queued delete, or a tap that only redirected a
  /// request already under way) or when the original state could not be
  /// read — then there is no Undo: guessing "public" would expose a private
  /// bookmark.
  Future<RemovedBookmark?> toggle(BookmarkKey key) async {
    final store = _ref.read(bookmarkStoreProvider.notifier);
    final entry = store.entryOf(key);
    final wish = !(entry?.shown ?? false);
    if (entry != null && entry.isUnsettled) {
      await _redirect(store, entry, key, wish);
      return null;
    }
    return _settle(store, key, wish: wish);
  }

  /// Requests [wish], then follows the user's later taps ([settleToggle]).
  /// An add puts back [restore] — or what the delete before it removed, so
  /// tapping back mid-delete keeps a private bookmark private — and adds
  /// public otherwise. Returns what the last request removed when it was a
  /// confirmed delete.
  Future<RemovedBookmark?> _settle(
    BookmarkStore store,
    BookmarkKey key, {
    required bool wish,
    RemovedBookmark? restore,
  }) async {
    var removed = restore;
    Future<bool> request(bool target) async {
      if (!target) return _delete(store, key, (value) => removed = value);
      final restored = removed;
      removed = null;
      final op = store.beginAdd(
        key,
        restored?.restrict ?? BookmarkRestrict.public,
        tags: restored?.tags ?? const [],
      );
      return op != null && await _run(store, op);
    }

    final settled = await settleToggle(
      first: () => request(wish),
      request: request,
      nextWish: () => store.entryOf(key)?.wish,
    );
    return settled ? removed : null;
  }

  /// A tap while [entry] is unsettled. In flight, it only records the wish;
  /// the running [settleToggle] follows it. Queued offline, the tap can
  /// only mean "back to the confirmed value": the queued intent is dropped
  /// and its operation cancelled. A replay already running ignores the tap
  /// — it settles in a moment.
  Future<void> _redirect(
    BookmarkStore store,
    BookmarkEntry entry,
    BookmarkKey key,
    bool wish,
  ) async {
    final op = entry.pending;
    if (op == null || !entry.isQueued) {
      store.want(key, wish);
      return;
    }
    final dropped = await _ref
        .read(actionQueueProvider)
        .dropPending(owner: op.accountId, dedupeKey: _dedupeKey(key));
    if (dropped) store.cancel(op);
  }

  /// Deletes [key], reporting what it removes to [onRemoved] before the
  /// request so Undo can restore it.
  Future<bool> _delete(
    BookmarkStore store,
    BookmarkKey key,
    void Function(RemovedBookmark? removed) onRemoved,
  ) async {
    final entry = store.entryOf(key);
    final op = store.beginDelete(key);
    if (op == null) return false;
    final local = entry == null ? null : _confirmedLocally(key, entry);
    onRemoved(local ?? await _fetchRemoved(key, op));
    return _run(store, op);
  }

  /// The local entry is exact only right after an add confirmed in this
  /// session: remote observations carry the visibility but never the tags.
  static RemovedBookmark? _confirmedLocally(
    BookmarkKey key,
    BookmarkEntry entry,
  ) {
    final restrict = entry.restrict;
    if (restrict == null ||
        entry.status != MutationStatus.confirmed ||
        entry.confirmedRevision == null) {
      return null;
    }
    return RemovedBookmark(key: key, restrict: restrict, tags: entry.tags);
  }

  /// Reads visibility and tags from the server before the delete; null
  /// when that fails — the delete still goes ahead, without Undo.
  Future<RemovedBookmark?> _fetchRemoved(BookmarkKey key, BookmarkOp op) async {
    try {
      final detail = await _ref
          .read(bookmarkRepositoryProvider)
          .fetchDetail(key, cancelToken: op.cancelToken);
      final restrict = detail.restrict;
      if (!detail.isBookmarked || restrict == null) return null;
      return RemovedBookmark(
        key: key,
        restrict: restrict,
        tags: [
          for (final tag in detail.tags)
            if (tag.isRegistered) tag.name,
        ],
      );
    } on Object {
      return null;
    }
  }

  /// Sheet confirm and Undo: add (or overwrite an existing bookmark — the
  /// server treats add as replace) with the chosen restrict and full tag
  /// set. Taps on the heart meanwhile are followed up like [toggle]'s. An
  /// unsettled entry suppresses the request.
  Future<void> addWithRestrict(
    BookmarkKey key,
    BookmarkRestrict restrict, {
    List<String> tags = const [],
  }) async {
    final store = _ref.read(bookmarkStoreProvider.notifier);
    if (store.entryOf(key)?.isUnsettled ?? false) return;
    await _settle(
      store,
      key,
      wish: true,
      restore: RemovedBookmark(key: key, restrict: restrict, tags: tags),
    );
  }

  /// True when the server confirmed [op].
  Future<bool> _run(BookmarkStore store, BookmarkOp op) async {
    final repository = _ref.read(bookmarkRepositoryProvider);
    try {
      switch ((op.key.type, op.kind)) {
        case (BookmarkEntityType.illust, BookmarkOpKind.add):
          await repository.addIllust(
            op.key.id,
            op.restrict,
            tags: op.tags,
            cancelToken: op.cancelToken,
          );
        case (BookmarkEntityType.illust, BookmarkOpKind.delete):
          await repository.deleteIllust(op.key.id, cancelToken: op.cancelToken);
        case (BookmarkEntityType.novel, BookmarkOpKind.add):
          await repository.addNovel(
            op.key.id,
            op.restrict,
            tags: op.tags,
            cancelToken: op.cancelToken,
          );
        case (BookmarkEntityType.novel, BookmarkOpKind.delete):
          await repository.deleteNovel(op.key.id, cancelToken: op.cancelToken);
      }
      store.commit(op);
      // A completed mutation is connectivity evidence — piggyback a queue
      // drain so earlier offline intents replay immediately.
      pumpActionQueue(_ref);
      return true;
    } on ApiCancelled {
      // Cancellation restores the confirmed view without an error banner.
      store.fail(op, const ApiCancelled());
    } on ApiError catch (error) {
      if (await _enqueueOffline(op, error)) {
        store.markQueued(op);
      } else {
        store.fail(op, error);
      }
    } on Object catch (error) {
      // Unexpected failures must never leave a pending entry stuck; the
      // error stays observable in the store entry and the UI.
      store.fail(op, error);
    }
    return false;
  }

  /// Connectivity-class failures persist the intent instead of failing the
  /// entry: the store keeps its pending state and the queued action replays
  /// through the same repository once the queue drains. Returns true when
  /// the intent is durably queued; a store failure falls back to the
  /// visible error path.
  Future<bool> _enqueueOffline(BookmarkOp op, ApiError error) async {
    if (!isConnectivityError(error)) return false;
    try {
      await _ref
          .read(actionQueueProvider)
          .enqueue(
            owner: op.accountId,
            type: op.kind == BookmarkOpKind.add
                ? ActionTypes.bookmarkAdd
                : ActionTypes.bookmarkDelete,
            dedupeKey: _dedupeKey(op.key),
            payload: {
              'entity': op.key.type.name,
              'id': op.key.id,
              if (op.kind == BookmarkOpKind.add) ...{
                'restrict': op.restrict.name,
                'tags': op.tags,
              },
            },
          );
      return true;
    } on Object {
      return false;
    }
  }
}

final bookmarkActionsProvider = Provider<_BookmarkActions>((ref) {
  return _BookmarkActions(ref);
});
