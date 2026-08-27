import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import 'bookmark_models.dart';

/// Canonical, account-scoped bookmark mutation store (design §Architecture).
///
/// All surfaces (feed cards, detail, future search/ranking) subscribe to the
/// same key, so a confirmed change is visible everywhere instantly (R7).
///
/// Revision contract:
/// - Every mutation begin and every remote-affecting commit increments the
///   global revision counter.
/// - [commit]/[fail] only apply to the entry whose pending op revision still
///   matches — superseded/late completions are dropped (R5).
/// - [observeRemote] accepts the store revision captured when the fetch that
///   produced the snapshot started; snapshots older than the entry's last
///   local confirmation never regress it (R2).
class BookmarkStore extends Notifier<Map<BookmarkKey, BookmarkEntry>> {
  int _revision = 0;

  /// Set by illustStoreProvider wiring: mirrors confirmed changes into the
  /// shared entity payloads. A closure instead of a provider read so the
  /// dependency graph stays one-directional (illustStore → bookmarkStore).
  void Function(BookmarkKey key, bool bookmarked)? onConfirmed;

  @override
  Map<BookmarkKey, BookmarkEntry> build() {
    // Account scoping (R8): watching only the current account id means a
    // switch/logout rebuilds with an empty map; account A state can never
    // leak into account B.
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return {};
  }

  /// Current global revision. Fetchers capture this BEFORE issuing the
  /// request and pass it to [IllustStore.mergeAll] as the snapshot revision.
  int revisionNow() => _revision;

  BookmarkEntry? entryOf(BookmarkKey key) => state[key];

  /// Begins a public/private add. Returns null when suppressed (an operation
  /// is already pending for the key — R5 duplicate suppression).
  BookmarkOp? beginAdd(BookmarkKey key, BookmarkRestrict restrict) =>
      _begin(key, BookmarkOpKind.add, restrict);

  /// Begins a delete. Returns null when suppressed.
  BookmarkOp? beginDelete(BookmarkKey key) =>
      _begin(key, BookmarkOpKind.delete, BookmarkRestrict.public);

  BookmarkOp? _begin(
    BookmarkKey key,
    BookmarkOpKind kind,
    BookmarkRestrict restrict,
  ) {
    final entry = state[key];
    if (entry != null && entry.isPending) return null;
    final op = BookmarkOp(
      key: key,
      revision: ++_revision,
      kind: kind,
      restrict: restrict,
    );
    // Non-optimistic (R4): confirmed value and icon stay unchanged while
    // pending; any previous error is superseded.
    state = {
      ...state,
      key: BookmarkEntry(
        bookmarked: entry?.bookmarked ?? false,
        restrict: entry?.restrict,
        pending: op,
      ),
    };
    return op;
  }

  /// Confirms an operation. No-op when the op was superseded.
  void commit(BookmarkOp op) {
    final entry = state[op.key];
    if (entry == null || entry.pending?.revision != op.revision) return;
    final added = op.kind == BookmarkOpKind.add;
    state = {
      ...state,
      op.key: BookmarkEntry(
        bookmarked: added,
        restrict: added ? op.restrict : null,
        confirmedRevision: op.revision,
      ),
    };
    // Keep the shared entity payload aligned with the canonical store.
    onConfirmed?.call(op.key, added);
  }

  /// Fails an operation, restoring the confirmed view and surfacing the
  /// error (R5). No-op when the op was superseded.
  void fail(BookmarkOp op, Object error) {
    final entry = state[op.key];
    if (entry == null || entry.pending?.revision != op.revision) return;
    state = {
      ...state,
      op.key: entry.copyWith(pending: null, error: error, clearPending: true),
    };
  }

  /// Merges a remote bookmark snapshot (API payloads routed through
  /// IllustStore.mergeAll).
  ///
  /// Rules:
  /// - A pending operation owns the truth until it settles; remote values
  ///   are ignored while one is in flight.
  /// - A snapshot captured before the entry's last local confirmation
  ///   ([snapshotRevision] < [BookmarkEntry.confirmedRevision]) is stale and
  ///   ignored. Snapshots captured after it are fresh and may legitimately
  ///   differ (e.g. bookmarked from another client).
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
      ),
    };
  }
}

final bookmarkStoreProvider =
    NotifierProvider<BookmarkStore, Map<BookmarkKey, BookmarkEntry>>(
      BookmarkStore.new,
    );
