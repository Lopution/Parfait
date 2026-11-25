/// Row-level access for the `feed_snapshots` table owned by [FeedDatabase].
/// A snapshot is the last-committed page-one view of one feed: ordered ids
/// plus the JSON-encoded entities they resolve to, so a cold start can
/// render content before the network answers.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../platform/app_storage_paths.dart';
import 'feed_database.dart';
import 'feed_snapshot_codec.dart';

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

/// Undecoded `feed_snapshots` row returned by [FeedSnapshotStore.readRaw] so
/// callers can offload JSON decoding and entity construction to `DataWorker`.
class RawFeedSnapshot {
  const RawFeedSnapshot({
    required this.idsJson,
    required this.entitiesJson,
    required this.savedAt,
    this.cursor,
    this.snapshotVersion = 1,
  });

  final String idsJson;
  final String entitiesJson;
  final String? cursor;
  final DateTime savedAt;
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

  /// Reads the raw JSON columns for one feed without decoding on the calling
  /// isolate. Expired rows are deleted immediately and counted in
  /// [discardedCount]; a miss returns null.
  Future<RawFeedSnapshot?> readRaw(
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
    if (_now().difference(savedAt) > maxAge) {
      _discardedCount++;
      await _delete(db, accountId, feedKey);
      return null;
    }
    final idsJson = row['ids'];
    final entitiesJson = row['entities'];
    final version = row['snapshot_version'];
    if (idsJson is! String || entitiesJson is! String || version is! int) {
      _discardedCount++;
      await _delete(db, accountId, feedKey);
      return null;
    }
    return RawFeedSnapshot(
      idsJson: idsJson,
      entitiesJson: entitiesJson,
      cursor: row['cursor'] as String?,
      savedAt: savedAt,
      snapshotVersion: version,
    );
  }

  /// Deletes a corrupt snapshot row discovered during worker-side decoding
  /// and increments [discardedCount].
  Future<void> discardCorrupt(String accountId, String feedKey) async {
    _discardedCount++;
    final db = await _database.database;
    await _delete(db, accountId, feedKey);
  }

  /// Reads the snapshot for one feed. Expired or undecodable rows are
  /// deleted and reported through [discardedCount]; a miss returns null.
  Future<FeedSnapshot?> read(
    String accountId,
    String feedKey, {
    Duration maxAge = maxAge,
  }) async {
    final raw = await readRaw(accountId, feedKey, maxAge: maxAge);
    if (raw == null) return null;
    final snapshot = _decodeRaw(raw);
    if (snapshot == null) {
      await discardCorrupt(accountId, feedKey);
      return null;
    }
    return snapshot;
  }

  FeedSnapshot? _decodeRaw(RawFeedSnapshot raw) {
    try {
      final ids = [
        for (final id in jsonDecode(raw.idsJson) as List<dynamic>) id as int,
      ];
      final entities = jsonDecode(raw.entitiesJson) as Map<String, Object?>;
      return FeedSnapshot(
        ids: ids,
        entities: entities,
        cursor: raw.cursor,
        savedAt: raw.savedAt,
        snapshotVersion: raw.snapshotVersion,
      );
    } on Object {
      return null;
    }
  }

  /// Upserts one feed's snapshot and evicts rows beyond the per-account cap.
  /// Encodes on the calling isolate; feeds write through [writeEncoded].
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

  /// [write] for a snapshot already encoded (on the data worker).
  Future<void> writeEncoded(
    String accountId,
    String feedKey,
    EncodedFeedSnapshot snapshot, {
    String? cursor,
    int snapshotVersion = 1,
  }) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.insert(FeedDatabase.snapshotTable, {
        'account_id': accountId,
        'feed_key': feedKey,
        'ids': snapshot.ids,
        'entities': snapshot.entities,
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
  final database = FeedDatabase(
    databasePath: ref
        .watch(appStoragePathsProvider)
        .databasePath(FeedDatabase.databaseName),
  );
  ref.onDispose(() => unawaited(database.close()));
  return database;
});

final feedSnapshotStoreProvider = Provider<FeedSnapshotStore>((ref) {
  return FeedSnapshotStore(database: ref.watch(feedDatabaseProvider));
});
