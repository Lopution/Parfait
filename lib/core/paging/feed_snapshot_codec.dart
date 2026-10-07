/// Typed bridge between a feed's shared entity store and the persisted
/// snapshot payload. Concrete feeds that opt into snapshot cold-start supply
/// a codec; feeds without one simply never persist. See
/// `feed_snapshot_store.dart` and `paged_feed_controller.dart`.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Encodes/decodes one entity type for `feed_snapshots.entities`.
///
/// The payload column stores `{entityType: {id: encoded}}` so a reader can
/// verify codec compatibility before decoding. Entity types are erased at
/// this boundary (`Object?` payloads keyed by id-string) because one
/// controller may serve different entity types per family key — concrete
/// codecs keep the real types internally.
abstract class FeedSnapshotCodec {
  const FeedSnapshotCodec();

  /// Discriminator persisted as the entities-map key ('illust', 'novel').
  String get entityType;

  /// Snapshot format version persisted per row; bump when the encoded
  /// payload becomes unreadable by older decoders.
  int get snapshotVersion => 1;

  /// The entities of [ids] still in the shared store, by id; missing ones
  /// are skipped. Read on the UI isolate.
  Map<int, Object> lookupEntities(Ref ref, List<int> ids);

  /// One entity's persisted payload. Pure: it runs on the data worker, so
  /// codecs stay stateless (`const`).
  Object? encodeEntity(Object entity);

  /// Decodes the persisted `{idString: payload}` map, merges the entities
  /// into the shared store and returns the subset of [ids] that decoded
  /// (order preserved). Corrupt entries drop their id.
  List<int> restoreEntities(
    Ref ref,
    List<int> ids,
    Map<String, Object?> entitiesJson,
  );
}

/// One snapshot write ready for storage: ids and
/// `{entityType: {idString: payload}}`, both as JSON text.
typedef EncodedFeedSnapshot = ({String ids, String entities});

/// Encodes one snapshot write; the data worker's task, so it is top-level.
EncodedFeedSnapshot encodeFeedSnapshot(
  ({FeedSnapshotCodec codec, List<int> ids, Map<int, Object> entities}) input,
) {
  final codec = input.codec;
  return (
    ids: jsonEncode(input.ids),
    entities: jsonEncode({
      codec.entityType: {
        for (final MapEntry(:key, :value) in input.entities.entries)
          '$key': codec.encodeEntity(value),
      },
    }),
  );
}
