/// Canonical account-scoped novel entities shared by feeds and the reader.
/// [NovelStore] owns entity merges while reader layout remains view-local.
/// See `frontend/state-management.md`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../bookmark/bookmark_models.dart';
import '../bookmark/bookmark_store.dart';
import 'novel_entity.dart';

/// Account-scoped canonical Novel entity map. Feeds keep ordered IDs and
/// detail pages read the same entity, just like the existing IllustStore.
class _NovelStore extends Notifier<Map<int, NovelEntity>> {
  @override
  Map<int, NovelEntity> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return {};
  }

  NovelEntity? get(int id) => state[id];

  List<NovelEntity> getAll(Iterable<int> ids) => [
    for (final id in ids)
      if (state[id] != null) state[id]!,
  ];

  void mergeAll(Iterable<NovelEntity> incoming) {
    final bookmarks = ref.read(bookmarkStoreProvider.notifier);
    final next = Map<int, NovelEntity>.of(state);
    for (final entity in incoming) {
      // Forward the remote snapshot first so a pending/confirmed mutation
      // wins over whatever the feed or detail payload claims (same R2 rule
      // as IllustStore).
      bookmarks.observeRemote(
        BookmarkKey(BookmarkEntityType.novel, entity.id),
        bookmarked: entity.isBookmarked,
      );
      final bookmarkAuthority = bookmarks
          .entryOf(BookmarkKey(BookmarkEntityType.novel, entity.id))
          ?.bookmarked;
      final existing = next[entity.id];
      if (existing == null) {
        next[entity.id] = bookmarkAuthority == null
            ? entity
            : entity.copyWith(isBookmarked: bookmarkAuthority);
        continue;
      }
      // Metadata feeds do not contain body content. A preview must never
      // erase a body already loaded by the reader.
      next[entity.id] = entity.copyWith(
        paragraphs: entity.contentAvailable
            ? entity.paragraphs
            : existing.paragraphs,
        markup: entity.contentAvailable ? entity.markup : existing.markup,
        contentVersion: entity.contentAvailable
            ? entity.contentVersion
            : existing.contentVersion,
        contentAvailable: entity.contentAvailable || existing.contentAvailable,
        embeddedImages: entity.embeddedImages.isNotEmpty
            ? entity.embeddedImages
            : existing.embeddedImages,
        embeddedIllustThumbs: entity.embeddedIllustThumbs.isNotEmpty
            ? entity.embeddedIllustThumbs
            : existing.embeddedIllustThumbs,
        seriesPrevId: entity.seriesPrevId ?? existing.seriesPrevId,
        seriesNextId: entity.seriesNextId ?? existing.seriesNextId,
        caption: entity.caption.isNotEmpty ? entity.caption : existing.caption,
        tags: entity.tags.isNotEmpty ? entity.tags : existing.tags,
        isBookmarked:
            bookmarkAuthority ?? (entity.isBookmarked || existing.isBookmarked),
      );
    }
    state = next;
  }

  /// Applies a confirmed bookmark change from the shared BookmarkStore.
  void updateBookmark(int id, bool bookmarked) {
    final existing = state[id];
    if (existing != null) {
      state = {...state, id: existing.copyWith(isBookmarked: bookmarked)};
    }
  }

  void clear() => state = {};
}

final novelStoreProvider = NotifierProvider<_NovelStore, Map<int, NovelEntity>>(
  _NovelStore.new,
);
