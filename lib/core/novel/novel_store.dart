import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import 'novel_entity.dart';

/// Account-scoped canonical Novel entity map. Feeds keep ordered IDs and
/// detail pages read the same entity, just like the existing IllustStore.
class NovelStore extends Notifier<Map<int, NovelEntity>> {
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
    final next = Map<int, NovelEntity>.of(state);
    for (final entity in incoming) {
      final existing = next[entity.id];
      if (existing == null) {
        next[entity.id] = entity;
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
        caption: entity.caption.isNotEmpty ? entity.caption : existing.caption,
        tags: entity.tags.isNotEmpty ? entity.tags : existing.tags,
      );
    }
    state = next;
  }

  void clear() => state = {};
}

final novelStoreProvider = NotifierProvider<NovelStore, Map<int, NovelEntity>>(
  NovelStore.new,
);
