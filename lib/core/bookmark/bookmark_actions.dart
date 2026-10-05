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

/// UI-facing bookmark actions: store begin → repository call → commit/fail.
///
/// Widgets never call the repository or mutate the store directly (design
/// §Architecture); suppressions surface as a null op and simply do nothing.
class _BookmarkActions {
  _BookmarkActions(this._ref);

  final Ref _ref;

  /// Short-press behaviour (beta56 changeBookmarkState): not bookmarked →
  /// public add; bookmarked → delete. Pending entries suppress the request.
  ///
  /// Returns what a delete removed, for Undo. Null when nothing was removed
  /// (an add, a suppressed request, a failure or a queued delete) or when
  /// the original state could not be read — then there is no Undo: guessing
  /// "public" would expose a private bookmark.
  Future<RemovedBookmark?> toggle(BookmarkKey key) async {
    final store = _ref.read(bookmarkStoreProvider.notifier);
    final entry = store.entryOf(key);
    if (entry == null || !entry.bookmarked) {
      final op = store.beginAdd(key, BookmarkRestrict.public);
      if (op != null) await _run(store, op);
      return null;
    }
    final op = store.beginDelete(key);
    if (op == null) return null;
    final removed =
        _confirmedLocally(key, entry) ?? await _fetchRemoved(key, op);
    return await _run(store, op) ? removed : null;
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

  /// Sheet confirm: add (or overwrite an existing bookmark — the server treats
  /// add as replace) with the chosen restrict and full tag set. Pending
  /// entries suppress the request.
  Future<void> addWithRestrict(
    BookmarkKey key,
    BookmarkRestrict restrict, {
    List<String> tags = const [],
  }) async {
    final store = _ref.read(bookmarkStoreProvider.notifier);
    final op = store.beginAdd(key, restrict, tags: tags);
    if (op == null) return;
    await _run(store, op);
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
      if (!await _enqueueOffline(op, error)) store.fail(op, error);
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
            // Target-scoped key: a pending add and a later delete coalesce
            // to the last intent.
            dedupeKey: 'bookmark:${op.key.type.name}:${op.key.id}',
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
