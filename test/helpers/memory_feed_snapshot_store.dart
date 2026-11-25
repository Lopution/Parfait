import 'dart:convert';

import 'package:parfait/core/paging/feed_snapshot_codec.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';

/// In-memory stand-in for [FeedSnapshotStore]: each world gets a fresh
/// instance so a snapshot committed by one test cannot leak into the next
/// world's cold start (sqflite's singleInstance cache would share the
/// default `feeds.db` across the whole test file).
class MemoryFeedSnapshotStore implements FeedSnapshotStore {
  final _rows = <String, RawFeedSnapshot>{};
  int _discardedCount = 0;

  @override
  int get discardedCount => _discardedCount;

  @override
  int get maxEntriesPerAccount => 64;

  @override
  Future<RawFeedSnapshot?> readRaw(
    String accountId,
    String feedKey, {
    Duration maxAge = FeedSnapshotStore.maxAge,
  }) async => _rows['$accountId|$feedKey'];

  @override
  Future<void> discardCorrupt(String accountId, String feedKey) async {
    _discardedCount++;
    _rows.remove('$accountId|$feedKey');
  }

  @override
  Future<FeedSnapshot?> read(
    String accountId,
    String feedKey, {
    Duration maxAge = FeedSnapshotStore.maxAge,
  }) async {
    final raw = await readRaw(accountId, feedKey, maxAge: maxAge);
    if (raw == null) return null;
    try {
      return FeedSnapshot(
        ids: [for (final id in jsonDecode(raw.idsJson) as List) id as int],
        entities: jsonDecode(raw.entitiesJson) as Map<String, Object?>,
        savedAt: raw.savedAt,
        cursor: raw.cursor,
        snapshotVersion: raw.snapshotVersion,
      );
    } on Object {
      await discardCorrupt(accountId, feedKey);
      return null;
    }
  }

  @override
  Future<void> write(
    String accountId,
    String feedKey, {
    required List<int> ids,
    required Map<String, Object?> entities,
    String? cursor,
    int snapshotVersion = 1,
  }) => writeEncoded(
    accountId,
    feedKey,
    (ids: jsonEncode(ids), entities: jsonEncode(entities)),
    cursor: cursor,
    snapshotVersion: snapshotVersion,
  );

  @override
  Future<void> writeEncoded(
    String accountId,
    String feedKey,
    EncodedFeedSnapshot snapshot, {
    String? cursor,
    int snapshotVersion = 1,
  }) async {
    _rows['$accountId|$feedKey'] = RawFeedSnapshot(
      idsJson: snapshot.ids,
      entitiesJson: snapshot.entities,
      savedAt: DateTime.now(),
      cursor: cursor,
      snapshotVersion: snapshotVersion,
    );
  }

  @override
  Future<void> clearAccount(String accountId) async {
    _rows.removeWhere((key, _) => key.startsWith('$accountId|'));
  }
}
