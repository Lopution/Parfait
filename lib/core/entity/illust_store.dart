import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../bookmark/bookmark_models.dart';
import '../bookmark/bookmark_store.dart';
import 'illust_entity.dart';

/// Shared, account-scoped store of illust entities keyed by work ID.
///
/// Feeds (recommended, ranking, search, bookmarks) only keep ordered ID
/// lists; the single entity copy lives here so Recommended, Detail and any
/// future surface observe identical data (design §4.4).
class IllustStore {
  final Map<int, IllustEntity> _entities = {};

  void Function(
    int id,
    bool? bookmarked,
    BookmarkRestrict? restrict,
    int? snapshotRevision,
  )?
  _observeRemote;

  bool? Function(int id)? _authorityOf;

  int Function()? _revisionNow;

  /// Binds the canonical BookmarkStore (wired once in illustStoreProvider).
  /// Callbacks keep the two stores decoupled without import cycles:
  /// - [observeRemote] forwards remote snapshots with their fetch-time
  ///   revision so the BookmarkStore can apply its own staleness gates.
  /// - [authorityOf] lets merges use the locally confirmed value as the
  ///   authoritative `isBookmarked` (BookmarkStore owns mutations, R2).
  /// - [revisionNow] exposes the revision to fetch sites.
  /// - [onConfirmedSync] mirrors confirmed changes back into entity payloads.
  void bindBookmarks({
    required void Function(
      int id,
      bool? bookmarked,
      BookmarkRestrict? restrict,
      int? snapshotRevision,
    )
    observeRemote,
    required bool? Function(int id) authorityOf,
    required int Function() revisionNow,
  }) {
    _observeRemote = observeRemote;
    _authorityOf = authorityOf;
    _revisionNow = revisionNow;
  }

  /// Store revision for fetch sites to capture BEFORE issuing a request so
  /// the response can be staleness-gated on merge (0 when unbound).
  int bookmarkRevisionNow() => _revisionNow?.call() ?? 0;

  /// Returns all known entities for [ids] in the given order. Unknown IDs
  /// (should not happen) are skipped.
  List<IllustEntity> getAll(Iterable<int> ids) => [
    for (final id in ids)
      if (_entities[id] != null) _entities[id]!,
  ];

  IllustEntity? get(int id) => _entities[id];

  /// Merges entities: newer parse wins; bookmark state follows the bound
  /// BookmarkStore when bound (remote snapshots are forwarded with the
  /// fetch-time revision and the confirmed local value wins — R2); when
  /// unbound the legacy no-regress OR rule keeps older snapshots from
  /// clearing a bookmark they have not observed. Page-URL payloads
  /// (`metaPages`/`metaSinglePageOriginalUrl`) are kept when only the older
  /// snapshot carries them (detail → feed refresh must not strip
  /// viewer/download URLs); trimmed payloads with an empty `caption`/`tags`
  /// never erase richer values already observed (detail fields must not
  /// regress, parent AC); `visible: false` sticks once seen.
  void mergeAll(
    Iterable<IllustEntity> incoming, {
    int? bookmarkSnapshotRevision,
  }) {
    for (final entity in incoming) {
      // Forward the remote snapshot before anything else so the bound
      // BookmarkStore can gate it; the authority read below then reflects
      // the post-gate value.
      _observeRemote?.call(
        entity.id,
        entity.isBookmarked,
        null,
        bookmarkSnapshotRevision,
      );
      final bookmarkAuthority = _authorityOf?.call(entity.id);
      final existing = _entities[entity.id];
      if (existing == null || existing == entity) {
        _entities[entity.id] = bookmarkAuthority == null
            ? entity
            : entity.copyWith(isBookmarked: bookmarkAuthority);
        continue;
      }
      _entities[entity.id] = entity.copyWith(
        isBookmarked:
            bookmarkAuthority ?? (entity.isBookmarked || existing.isBookmarked),
        caption: entity.caption.isNotEmpty ? entity.caption : existing.caption,
        tags: entity.tags.isNotEmpty ? entity.tags : existing.tags,
        metaPages: entity.metaPages.isNotEmpty
            ? entity.metaPages
            : existing.metaPages,
        metaSinglePageOriginalUrl:
            entity.metaSinglePageOriginalUrl ??
            existing.metaSinglePageOriginalUrl,
        visible: entity.visible && existing.visible,
      );
      // pageCount never shrinks: a feed snapshot with page_count=1 must not
      // erase a detail payload's multi-page count (AC: merge 不倒退).
      final merged = _entities[entity.id]!;
      if (existing.pageCount > merged.pageCount) {
        _entities[entity.id] = merged.copyWith(pageCount: existing.pageCount);
      }
    }
  }

  /// Applies a confirmed bookmark state change coming from the shared
  /// BookmarkStore (also used as the commit sync target).
  void updateBookmark(int id, bool bookmarked) {
    final existing = _entities[id];
    if (existing != null) {
      _entities[id] = existing.copyWith(isBookmarked: bookmarked);
    }
  }

  /// Clears account-scoped data (account switch).
  void clear() => _entities.clear();
}

final illustStoreProvider = Provider<IllustStore>((ref) {
  final store = IllustStore();
  final bookmarks = ref.watch(bookmarkStoreProvider.notifier);
  store.bindBookmarks(
    observeRemote: (id, bookmarked, restrict, snapshotRevision) =>
        bookmarks.observeRemote(
          BookmarkKey(BookmarkEntityType.illust, id),
          bookmarked: bookmarked,
          restrict: restrict,
          snapshotRevision: snapshotRevision,
        ),
    authorityOf: (id) => bookmarks
        .entryOf(BookmarkKey(BookmarkEntityType.illust, id))
        ?.bookmarked,
    revisionNow: bookmarks.revisionNow,
  );
  bookmarks.onConfirmed =
      (key, bookmarked) => store.updateBookmark(key.id, bookmarked);
  return store;
});
