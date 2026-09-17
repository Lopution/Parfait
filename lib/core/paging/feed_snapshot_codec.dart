/// Typed bridge between a feed's shared entity store and the persisted
/// snapshot payload. Concrete feeds that opt into snapshot cold-start supply
/// a codec; feeds without one simply never persist. See
/// `feed_snapshot_store.dart` and `paged_feed_controller.dart`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Encodes/decodes one entity type for `feed_snapshots.entities`.
///
/// The payload column stores `{entityType: {id: encoded}}` so a reader can
/// verify codec compatibility before decoding. [E] is the entity type
/// (`IllustEntity`, `NovelEntity`, ...).
abstract class FeedSnapshotCodec<E> {
  /// Discriminator persisted as the entities-map key ('illust', 'novel').
  String get entityType;

  /// Reads the currently live entities for [ids] out of the shared entity
  /// store; ids whose entity is gone are skipped.
  Map<int, E> readEntities(Ref ref, List<int> ids);

  /// Merges decoded entities back into the shared entity store so cards
  /// render from the same source as a fresh fetch.
  void mergeEntities(Ref ref, Map<int, E> entities);

  /// Encodes one entity to a JSON-encodable value.
  Object? encodeEntity(E entity);

  /// Decodes one persisted entity; returning null drops the entry.
  E? decodeEntity(Object? json);

  /// Snapshot format version persisted per row; bump when [encodeEntity]
  /// output becomes unreadable by older decoders.
  int get snapshotVersion => 1;
}
