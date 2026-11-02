/// Canonical account-scoped novel entities shared by feeds and the reader.
/// [NovelStore] owns entity merges while reader layout remains view-local.
/// See `backend/stores.md`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../network/api_error.dart';
import '../bookmark/bookmark_models.dart';
import '../bookmark/bookmark_store.dart';
import 'novel_entity.dart';
import 'novel_repository.dart';

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
    final entities = incoming.toList(growable: false);
    // Forward the remote snapshots first so a pending/confirmed mutation
    // wins over whatever the feed or detail payload claims (same R2 rule
    // as IllustStore).
    bookmarks.observeRemoteAll([
      for (final entity in entities)
        (
          key: BookmarkKey(BookmarkEntityType.novel, entity.id),
          bookmarked: entity.isBookmarked,
          restrict: null,
        ),
    ]);
    final next = Map<int, NovelEntity>.of(state);
    for (final entity in entities) {
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
        markerPage: entity.contentAvailable
            ? entity.markerPage
            : existing.markerPage,
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

  /// Records the account's bookmark (marker) of novel [id] at [page], or
  /// none, once the account has it.
  void updateMarker(int id, int? page) {
    final entity = state[id];
    if (entity == null) return;
    state = {...state, id: entity.copyWith(markerPage: page)};
  }

  void clear() => state = {};
}

final novelStoreProvider = NotifierProvider<_NovelStore, Map<int, NovelEntity>>(
  _NovelStore.new,
);

/// The account's bookmark (Pixiv's marker) writes: one novel at a time,
/// straight to the server, the novel's [NovelEntity.markerPage] changed
/// in [novelStoreProvider] only once the server has it. The state is the
/// novels with a write on its way. Like mute edits, a marker write is an
/// idempotent set, so a pending flag per novel and the account boundary
/// are the whole protocol.
class _NovelMarkerWrites extends Notifier<Set<int>> {
  @override
  Set<int> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return const {};
  }

  /// Bookmarks Pixiv page [page] of novel [novelId], or removes its
  /// bookmark when [page] is null. The error reaches the caller, which
  /// says so; a second write while one runs does nothing.
  Future<void> write(int novelId, int? page) async {
    if (state.contains(novelId)) return;
    final claim = AccountClaim(ref);
    if (claim.accountId == null) throw const ApiUnauthorized('no account');
    state = {...state, novelId};
    try {
      final repository = ref.read(novelRepositoryProvider);
      if (page == null) {
        await repository.deleteMarker(novelId);
      } else {
        await repository.addMarker(novelId, page);
      }
      if (claim.holds) {
        ref.read(novelStoreProvider.notifier).updateMarker(novelId, page);
      }
    } finally {
      if (claim.holds) state = {...state}..remove(novelId);
    }
  }
}

final novelMarkerWritesProvider =
    NotifierProvider<_NovelMarkerWrites, Set<int>>(_NovelMarkerWrites.new);
