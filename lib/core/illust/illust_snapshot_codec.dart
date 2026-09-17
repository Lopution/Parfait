/// Feed-snapshot codec for [IllustEntity]. The entity's `toJson`/`fromJson`
/// pair already round-trips the API shape, so the codec is a thin typed
/// adapter over [IllustStore].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_entity.dart';
import '../entity/illust_store.dart';
import '../paging/feed_snapshot_codec.dart';

final class IllustSnapshotCodec extends FeedSnapshotCodec {
  const IllustSnapshotCodec();

  @override
  String get entityType => 'illust';

  @override
  Map<String, Object?> encodeEntities(Ref ref, List<int> ids) {
    final store = ref.read(illustStoreProvider);
    return {
      for (final id in ids)
        if (store.get(id) case final entity?) '$id': entity.toJson(),
    };
  }

  @override
  List<int> restoreEntities(
    Ref ref,
    List<int> ids,
    Map<String, Object?> entitiesJson,
  ) {
    final decoded = <IllustEntity>[];
    final restored = <int>[];
    for (final id in ids) {
      final payload = entitiesJson['$id'];
      if (payload is! Map<String, dynamic>) continue;
      try {
        decoded.add(IllustEntity.fromJson(payload));
        restored.add(id);
      } on Object {
        // A single corrupt entry drops only its id; the rest of the
        // snapshot still renders.
        continue;
      }
    }
    if (decoded.isNotEmpty) {
      ref.read(illustStoreProvider).mergeAll(decoded);
    }
    return restored;
  }
}
