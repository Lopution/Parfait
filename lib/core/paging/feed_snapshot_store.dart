/// Row-level access for the `feed_snapshots` table owned by [FeedDatabase].
/// A snapshot is the last-committed page-one view of one feed: ordered ids
/// plus the JSON-encoded entities they resolve to, so a cold start can
/// render content before the network answers. See `database-guidelines.md`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import 'feed_database.dart';

/// One decoded `feed_snapshots` row.
class FeedSnapshot {
  const FeedSnapshot({
    required this.ids,
    required this.entities,
    required this.savedAt,
    this.cursor,
    this.snapshotVersion = 1,
  });

  /// Ordered entity ids as the feed last showed them (already filtered).
  final List<int> ids;

  /// `{entityType: {id: payload}}` — decoded through the feed's codec.
  final Map<String, Object?> entities;

  /// Server cursor committed with page one, if any.
  final String? cursor;

  /// When this row was written.
  final DateTime savedAt;

  /// Codec format marker written by the producing snapshot version.
  final int snapshotVersion;
}

/// CRUD, expiry and per-account LRU eviction for feed snapshots.
///
/// Storage policy: at most [maxEntriesPerAccount] feeds per account (newest
/// `saved_at` wins), rows older than [maxAge] are discarded on read. The
/// store is codec-agnostic — callers pass already-encoded entity maps.
class FeedSnapshotStore {
  FeedSnapshotStore({
    required FeedDatabase database,
    DateTime Function()? now,
    this.maxEntriesPerAccount = 64,
  }) : _database = database,
       _now = now ?? DateTime.now;

  /// Rows older than this are treated as a miss and deleted.
  static const maxAge = Duration(hours: 24);

  final FeedDatabase _database;
  final DateTime Function() _now;

  /// Per-account feed cap; the least recently saved row is evicted first.
  final int maxEntriesPerAccount;

  /// Telemetry: rows discarded as expired or corrupt since construction.
  int get discardedCount => _discardedCount;
  int _discardedCount = 0;

  /// Reads the snapshot for one feed. Expired or undecodable rows are
  /// deleted and reported through [discardedCount]; a miss returns null.
  Future<FeedSnapshot?> read(
    String accountId,
    String feedKey, {
    Duration maxAge = maxAge,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      FeedDatabase.snapshotTable,
      columns: const [
        'ids',
        'entities',
        'cursor',
        'saved_at',
        'snapshot_version',
      ],
      where: 'account_id = ? AND feed_key = ?',
      whereArgs: [accountId, feedKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final savedAt = DateTime.fromMillisecondsSinceEpoch(row['saved_at'] as int);
    final expired = _now().difference(savedAt) > maxAge;
    final snapshot = expired ? null : _decode(row, savedAt);
    if (snapshot == null) {
      _discardedCount++;
      await _delete(db, accountId, feedKey);
      return null;
    }
    return snapshot;
  }

  FeedSnapshot? _decode(Map<String, Object?> row, DateTime savedAt) {
    try {
      final ids = [
        for (final id in jsonDecode(row['ids']! as String) as List<dynamic>)
          id as int,
      ];
      final entities =
          jsonDecode(row['entities']! as String) as Map<String, Object?>;
      return FeedSnapshot(
        ids: ids,
        entities: entities,
        cursor: row['cursor'] as String?,
        savedAt: savedAt,
        snapshotVersion: row['snapshot_version']! as int,
      );
    } on Object {
      return null;
    }
  }

  /// Upserts one feed's snapshot and evicts rows beyond the per-account cap.
  Future<void> write(
    String accountId,
    String feedKey, {
    required List<int> ids,
    required Map<String, Object?> entities,
    String? cursor,
    int snapshotVersion = 1,
  }) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.insert(FeedDatabase.snapshotTable, {
        'account_id': accountId,
        'feed_key': feedKey,
        'ids': jsonEncode(ids),
        'entities': jsonEncode(entities),
        'cursor': cursor,
        'saved_at': _now().millisecondsSinceEpoch,
        'snapshot_version': snapshotVersion,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete(
        FeedDatabase.snapshotTable,
        where:
            'account_id = ? AND feed_key IN ('
            'SELECT feed_key FROM ${FeedDatabase.snapshotTable} '
            'WHERE account_id = ? '
            'ORDER BY saved_at DESC LIMIT -1 OFFSET ?)',
        whereArgs: [accountId, accountId, maxEntriesPerAccount],
      );
    });
  }

  Future<void> _delete(Database db, String accountId, String feedKey) {
    return db.delete(
      FeedDatabase.snapshotTable,
      where: 'account_id = ? AND feed_key = ?',
      whereArgs: [accountId, feedKey],
    );
  }

  /// Drops every snapshot of an account (logout/teardown boundary).
  Future<void> clearAccount(String accountId) async {
    final db = await _database.database;
    await db.delete(
      FeedDatabase.snapshotTable,
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
  }
}

final feedDatabaseProvider = Provider<FeedDatabase>((ref) {
  final database = FeedDatabase();
  ref.onDispose(() => unawaited(database.close()));
  return database;
});

final feedSnapshotStoreProvider = Provider<FeedSnapshotStore>((ref) {
  return FeedSnapshotStore(database: ref.watch(feedDatabaseProvider));
});
