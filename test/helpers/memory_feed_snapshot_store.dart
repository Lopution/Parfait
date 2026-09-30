import 'package:pixiv_func/core/paging/feed_snapshot_store.dart';

/// In-memory stand-in for [FeedSnapshotStore]: each world gets a fresh
/// instance so a snapshot committed by one test cannot leak into the next
/// world's cold start (sqflite's singleInstance cache would share the
/// default `feeds.db` across the whole test file).
class MemoryFeedSnapshotStore implements FeedSnapshotStore {
  final _rows = <String, FeedSnapshot>{};

  @override
  int get discardedCount => 0;

  @override
  int get maxEntriesPerAccount => 64;

  @override
  Future<FeedSnapshot?> read(
    String accountId,
    String feedKey, {
    Duration maxAge = FeedSnapshotStore.maxAge,
  }) async => _rows['$accountId|$feedKey'];

  @override
  Future<void> write(
    String accountId,
    String feedKey, {
    required List<int> ids,
    required Map<String, Object?> entities,
    String? cursor,
    int snapshotVersion = 1,
  }) async {
    _rows['$accountId|$feedKey'] = FeedSnapshot(
      ids: ids,
      entities: entities,
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
