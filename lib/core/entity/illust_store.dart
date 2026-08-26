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

  /// Merges entities: newer parse wins; [isBookmarked] is never regressed to
  /// false by an older snapshot that simply has not observed a bookmark yet.
  void mergeAll(Iterable<IllustEntity> incoming) {
    for (final entity in incoming) {
      final existing = _entities[entity.id];
      if (existing == null || existing == entity) {
        _entities[entity.id] = entity;
        continue;
      }
      _entities[entity.id] = entity.copyWith(
        isBookmarked: entity.isBookmarked || existing.isBookmarked,
      );
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
