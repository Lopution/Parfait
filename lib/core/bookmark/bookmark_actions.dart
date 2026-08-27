import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_error.dart';
import 'bookmark_models.dart';
import 'bookmark_repository.dart';
import 'bookmark_store.dart';

/// UI-facing bookmark actions: store begin → repository call → commit/fail.
///
/// Widgets never call the repository or mutate the store directly (design
/// §Architecture); suppressions surface as a null op and simply do nothing.
class BookmarkActions {
  BookmarkActions(this._ref);

  final Ref _ref;

  /// Short-press behaviour (beta56 changeBookmarkState): not bookmarked →
  /// public add; bookmarked → delete. Pending entries suppress the request.
  Future<void> toggle(BookmarkKey key) async {
    final store = _ref.read(bookmarkStoreProvider.notifier);
    final entry = store.entryOf(key);
    final op = (entry?.bookmarked ?? false)
        ? store.beginDelete(key)
        : store.beginAdd(key, BookmarkRestrict.public);
    if (op == null) return;
    await _run(store, op);
  }

  /// Long-press sheet confirm: add with the chosen restrict. Pending entries
  /// suppress the request.
  Future<void> addWithRestrict(
    BookmarkKey key,
    BookmarkRestrict restrict,
  ) async {
    final store = _ref.read(bookmarkStoreProvider.notifier);
    final op = store.beginAdd(key, restrict);
    if (op == null) return;
    await _run(store, op);
  }

  Future<void> _run(BookmarkStore store, BookmarkOp op) async {
    final repository = _ref.read(bookmarkRepositoryProvider);
    try {
      switch (op.kind) {
        case BookmarkOpKind.add:
          await repository.addIllust(op.key.id, op.restrict);
        case BookmarkOpKind.delete:
          await repository.deleteIllust(op.key.id);
      }
      store.commit(op);
    } on ApiCancelled {
      // Cancellation restores the confirmed view without an error banner.
      store.fail(op, const ApiCancelled());
    } on ApiError catch (error) {
      store.fail(op, error);
    } on Object catch (error) {
      // Unexpected failures must never leave a pending entry stuck; the
      // error stays observable in the store entry and the UI.
      store.fail(op, error);
    }
  }
}

final bookmarkActionsProvider = Provider<BookmarkActions>((ref) {
  return BookmarkActions(ref);
});
