import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'illust_entity.dart';

/// Shared, account-scoped store of illust entities keyed by work ID.
///
/// Feeds (recommended, ranking, search, bookmarks) only keep ordered ID
/// lists; the single entity copy lives here so Recommended, Detail and any
/// future surface observe identical data (design §4.4).
class IllustStore {
  final Map<int, IllustEntity> _entities = {};

  /// Returns all known entities for [ids] in the given order. Unknown IDs
  /// (should not happen) are skipped.
  List<IllustEntity> getAll(Iterable<int> ids) => [
        for (final id in ids)
          if (_entities[id] != null) _entities[id]!,
      ];

  IllustEntity? get(int id) => _entities[id];

  /// Merges entities: newer parse wins; `isBookmarked` is never regressed to
  /// false by an older snapshot that simply has not observed a bookmark yet;
  /// page-URL payloads (`metaPages`/`metaSinglePageOriginalUrl`) are kept
  /// when only the older snapshot carries them (detail → feed refresh must
  /// not strip viewer/download URLs); trimmed payloads with an empty
  /// `caption`/`tags` never erase richer values already observed (detail
  /// fields must not regress, parent AC); `visible: false` sticks once seen.
  void mergeAll(Iterable<IllustEntity> incoming) {
    for (final entity in incoming) {
      final existing = _entities[entity.id];
      if (existing == null || existing == entity) {
        _entities[entity.id] = entity;
        continue;
      }
      _entities[entity.id] = entity.copyWith(
        isBookmarked: entity.isBookmarked || existing.isBookmarked,
        caption: entity.caption.isNotEmpty ? entity.caption : existing.caption,
        tags: entity.tags.isNotEmpty ? entity.tags : existing.tags,
        metaPages: entity.metaPages.isNotEmpty
            ? entity.metaPages
            : existing.metaPages,
        metaSinglePageOriginalUrl:
            entity.metaSinglePageOriginalUrl ?? existing.metaSinglePageOriginalUrl,
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

  /// Applies a bookmark state change coming from the shared BookmarkStore.
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
  return IllustStore();
});
