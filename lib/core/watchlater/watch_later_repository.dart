import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../entity/illust_entity.dart';
import 'watch_later_database.dart';

/// One locally-stashed illust. `payload` is the full [IllustEntity] JSON so
/// the list renders and opens detail without any network call.
class WatchLaterEntry {
  const WatchLaterEntry({required this.addedAt, required this.entity});

  final int addedAt;
  final IllustEntity entity;
}

/// CRUD over [WatchLaterDatabase]. Pure-local: no network, no remote sync —
/// the whole point of the list is that it works without connectivity.
class WatchLaterRepository {
  WatchLaterRepository({
    required WatchLaterDatabase database,
    DateTime Function()? now,
  }) : _database = database,
       _now = now ?? DateTime.now;

  final WatchLaterDatabase _database;
  final DateTime Function() _now;

  Future<List<WatchLaterEntry>> list(String accountId) async {
    final db = await _database.database;
    final rows = await db.query(
      WatchLaterDatabase.table,
      columns: const ['added_at', 'payload'],
      where: 'account_id = ?',
      whereArgs: [accountId],
      // Same-millisecond re-adds get a fresh rowid on REPLACE — use it as
      // the tiebreak so a re-stashed work still lands at the front.
      orderBy: 'added_at DESC, rowid DESC',
    );
    return [
      for (final row in rows)
        WatchLaterEntry(
          addedAt: row['added_at'] as int,
          entity: IllustEntity.fromJson(
            jsonDecode(row['payload'] as String) as Map<String, dynamic>,
          ),
        ),
    ];
  }

  /// Idempotent: re-adding an existing work refreshes `added_at` and the
  /// stored payload instead of failing.
  Future<void> add(String accountId, IllustEntity entity) async {
    final db = await _database.database;
    await db.insert(
      WatchLaterDatabase.table,
      _row(accountId, entity, _now().millisecondsSinceEpoch),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Puts [entries] back with their own `added_at` in one transaction, so
  /// each lands at its old position instead of jumping to the front.
  Future<void> restoreAll(
    String accountId,
    Iterable<WatchLaterEntry> entries,
  ) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in entries) {
        batch.insert(
          WatchLaterDatabase.table,
          _row(accountId, entry.entity, entry.addedAt),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Removes [illustIds] in one transaction.
  Future<void> removeAll(String accountId, Iterable<int> illustIds) async {
    final ids = illustIds.toSet();
    if (ids.isEmpty) return;
    final db = await _database.database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final id in ids) {
        batch.delete(
          WatchLaterDatabase.table,
          where: 'account_id = ? AND illust_id = ?',
          whereArgs: [accountId, id],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  static Map<String, Object> _row(
    String accountId,
    IllustEntity entity,
    int addedAt,
  ) => {
    'account_id': accountId,
    'illust_id': entity.id,
    'added_at': addedAt,
    'payload': jsonEncode(entity.toJson()),
  };

  Future<void> clear(String accountId) async {
    final db = await _database.database;
    await db.delete(
      WatchLaterDatabase.table,
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
  }
}
