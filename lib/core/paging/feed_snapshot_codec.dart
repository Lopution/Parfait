/// Typed bridge between a feed's shared entity store and the persisted
/// snapshot payload. Concrete feeds that opt into snapshot cold-start supply
/// a codec; feeds without one simply never persist. See
/// `feed_snapshot_store.dart` and `paged_feed_controller.dart`.
library;

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

  /// `{idString: payload}` for ids that still resolve to a live entity in
  /// the shared store. Missing entities are skipped.
  Map<String, Object?> encodeEntities(Ref ref, List<int> ids);

  /// Decodes the persisted `{idString: payload}` map, merges the entities
  /// into the shared store and returns the subset of [ids] that decoded
  /// (order preserved). Corrupt entries drop their id.
  List<int> restoreEntities(
    Ref ref,
    List<int> ids,
    Map<String, Object?> entitiesJson,
  );
}
