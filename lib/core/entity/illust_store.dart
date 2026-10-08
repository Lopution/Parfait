/// The canonical account-scoped illustration entity map and merge policy.
/// [IllustStore] owns shared entity writes; feeds retain ordered IDs only.
/// See `frontend/state-management.md`.
library;

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../bookmark/bookmark_models.dart';
import '../bookmark/bookmark_store.dart';
import '../novel/novel_store.dart';
import 'illust_entity.dart';

/// Payload provenance for entity merges (C3/audit R7.3).
///
/// - [feed]: sparse feed pages. Fields the payload does not carry must not
///   erase a richer value already observed (no-regress).
/// - [detail]: authoritative responses. An empty caption, empty tags,
///   `visible=false` or a reduced page count is a real server state and may
///   overwrite the previous snapshot.
enum EntityMergeSource { feed, detail }

/// Shared, account-scoped store of illust entities keyed by work ID.
///
/// Feeds (recommended, ranking, search, bookmarks) only keep ordered ID
/// lists; the single entity copy lives here so Recommended, Detail and any
/// future surface observe identical data (design §4.4).
class IllustStore {
  final Map<int, IllustEntity> _entities = {};

  /// When an API payload for each work was last merged.
  final Map<int, DateTime> _receivedAt = {};

  /// Works some detail payload has been merged for: their empty caption is
  /// real, not a list endpoint trimming it.
  final Set<int> _detailed = {};

  void Function(
    Iterable<(int id, bool bookmarked)> snapshots,
    int? snapshotRevision,
  )?
  _observeRemote;

  bool? Function(int id)? _authorityOf;

  int Function()? _revisionNow;

  /// Binds the canonical BookmarkStore (wired once in illustStoreProvider).
  /// Callbacks keep the two stores decoupled without import cycles:
  /// - [observeRemote] forwards a merge's remote snapshots, as one batch,
  ///   with their fetch-time revision so the BookmarkStore can apply its
  ///   own staleness gates.
  /// - [authorityOf] lets merges use the locally confirmed value as the
  ///   authoritative `isBookmarked` (BookmarkStore owns mutations, R2).
  /// - [revisionNow] exposes the revision to fetch sites.
  /// - [onConfirmedSync] mirrors confirmed changes back into entity payloads.
  void bindBookmarks({
    required void Function(
      Iterable<(int id, bool bookmarked)> snapshots,
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

  /// When the last feed or detail payload for [id] was merged; null when
  /// none was (an entity restored from local storage).
  DateTime? receivedAt(int id) => _receivedAt[id];

  /// Whether a detail payload for [id] has been merged.
  bool hasDetail(int id) => _detailed.contains(id);

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
  ///
  /// [fromLocalCache] marks entities restored from local storage: they say
  /// nothing about how fresh the work is, so [receivedAt] stays as it was.
  void mergeAll(
    Iterable<IllustEntity> incoming, {
    EntityMergeSource source = EntityMergeSource.feed,
    int? bookmarkSnapshotRevision,
    bool fromLocalCache = false,
  }) {
    final entities = incoming.toList(growable: false);
    // Forward the remote snapshots before anything else so the bound
    // BookmarkStore can gate them; the authority reads below then reflect
    // the post-gate values.
    _observeRemote?.call([
      for (final entity in entities) (entity.id, entity.isBookmarked),
    ], bookmarkSnapshotRevision);
    final now = clock.now();
    for (final entity in entities) {
      if (!fromLocalCache) _receivedAt[entity.id] = now;
      if (source == EntityMergeSource.detail) _detailed.add(entity.id);
      final bookmarkAuthority = _authorityOf?.call(entity.id);
      final existing = _entities[entity.id];
      if (existing == null || existing == entity) {
        _entities[entity.id] = bookmarkAuthority == null
            ? entity
            : entity.copyWith(isBookmarked: bookmarkAuthority);
        continue;
      }
      if (source == EntityMergeSource.detail) {
        // Authoritative detail payload: real server state wins, including
        // empty caption/tags, visible=false and a reduced page count. The
        // bookmark flag still follows the BookmarkStore authority when
        // bound (R2): mutations are owned there.
        _entities[entity.id] = entity.copyWith(
          isBookmarked:
              bookmarkAuthority ??
              (entity.isBookmarked || existing.isBookmarked),
          seriesId: entity.seriesKnown ? entity.seriesId : existing.seriesId,
          seriesKnown: entity.seriesKnown || existing.seriesKnown,
        );
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
        // U2: detail responses carry createDate but feed refreshes do not;
        // a date-less payload must never erase an observed date (same
        // no-regress rule as caption/metaPages).
        createDate: entity.createDate ?? existing.createDate,
        totalComments: entity.totalComments ?? existing.totalComments,
        // A payload that does not say leaves the known series alone.
        seriesId: entity.seriesKnown ? entity.seriesId : existing.seriesId,
        seriesKnown: entity.seriesKnown || existing.seriesKnown,
      );
      // pageCount never shrinks: a feed snapshot with page_count=1 must not
      // erase a detail payload's multi-page count (AC: merge 不倒退).
      final merged = _entities[entity.id]!;
      if (existing.pageCount > merged.pageCount) {
        _entities[entity.id] = merged.copyWith(pageCount: existing.pageCount);
      }
    }
  }

  /// Seeds true per-page sizes from the web pages endpoint into the stored
  /// entity (see [IllustEntity.withPageDimensions]). Not a payload of the
  /// work itself, so it leaves [receivedAt] and [hasDetail] alone. Returns
  /// whether anything changed.
  bool applyPageDimensions(int id, List<({int width, int height})> dims) {
    final current = _entities[id];
    if (current == null) return false;
    final enriched = current.withPageDimensions(dims);
    if (identical(enriched, current)) return false;
    _entities[id] = enriched;
    return true;
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
  void clear() {
    _entities.clear();
    _receivedAt.clear();
    _detailed.clear();
  }
}

final illustStoreProvider = Provider<IllustStore>((ref) {
  // Recreate the entity store on account changes so a feed from account A
  // cannot be rendered while account B is loading its own snapshot.
  ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
  final store = IllustStore();
  final bookmarks = ref.watch(bookmarkStoreProvider.notifier);
  store.bindBookmarks(
    observeRemote: (snapshots, snapshotRevision) => bookmarks.observeRemoteAll([
      for (final (id, bookmarked) in snapshots)
        (
          key: BookmarkKey(BookmarkEntityType.illust, id),
          bookmarked: bookmarked,
          restrict: null,
        ),
    ], snapshotRevision: snapshotRevision),
    authorityOf: (id) => bookmarks
        .entryOf(BookmarkKey(BookmarkEntityType.illust, id))
        ?.bookmarked,
    revisionNow: bookmarks.revisionNow,
  );
  bookmarks.onConfirmed = (key, bookmarked) => switch (key.type) {
    BookmarkEntityType.illust => store.updateBookmark(key.id, bookmarked),
    BookmarkEntityType.novel =>
      ref.read(novelStoreProvider.notifier).updateBookmark(key.id, bookmarked),
  };
  return store;
});
