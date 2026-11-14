/// Persistence boundary for the offline action queue. The sqflite
/// implementation lives on [ActionDatabase]; the in-memory variant keeps
/// engine tests free of sqlite.
library;

import 'package:meta/meta.dart';
import 'package:sqflite/sqflite.dart';

import '../paging/feed_database.dart';
import 'action_database.dart';
import 'action_models.dart';

/// CRUD the [ActionQueue] engine needs. All mutation methods are safe to
/// call inside a store-managed transaction; the sqlite implementation wraps
/// coalescing enqueue in one.
abstract interface class ActionStore {
  /// Inserts one pending row, replacing any *pending* row that shares the
  /// owner + dedupe key (last write wins). A running or failed row with the
  /// same key is left alone so in-flight replays finish and dead letters
  /// stay observable.
  Future<int> enqueue(StoredAction draft);

  /// The oldest pending row ready to run for [owner] — `status='pending'`
  /// and (`next_attempt_at` null or `<= nowMs`). Cross-owner rows are never
  /// returned.
  Future<StoredAction?> nextReady(String owner, int nowMs);

  /// Claims a pending row for replay. False when the row is gone or no
  /// longer pending — dropped by [deletePending] after [nextReady] read it.
  Future<bool> markRunning(int id);

  /// Returns a row to pending. [attempt] and [nextAttemptAtMs] carry the
  /// row-backoff schedule for row-scope retries; both stay null/unchanged
  /// for queue-scope cooldowns.
  Future<void> markPending(int id, {int? attempt, int? nextAttemptAtMs});

  /// Marks a row permanently failed after exhausting attempts.
  Future<void> markFailed(int id);

  /// Deletes a row — successful replay or explicit drop.
  Future<void> delete(int id);

  /// Deletes the *pending* row of owner + dedupe key. False when there is
  /// none — never queued, already replayed, or running right now.
  Future<bool> deletePending(String owner, String dedupeKey);

  /// Returns rows a killed process left `running` to pending, keeping
  /// their attempt count. A row superseded by a newer pending intent of
  /// the same owner + dedupe key is deleted instead. Only safe before this
  /// process's first replay, when no row can be running for real.
  Future<({int reset, int dropped})> recoverInterrupted();

  /// When [owner]'s first pending row becomes ready, in epoch ms — 0 for a
  /// row without backoff — or null when nothing is pending.
  Future<int?> nextPendingAt(String owner);

  /// All rows of one owner, oldest first (tests/diagnostics).
  Future<List<StoredAction>> listFor(String owner);

  /// Drops every row of an account (logout/teardown boundary).
  Future<void> clearAccount(String owner);
}

/// SQLite-backed store over `actions.db`'s `action_queue` table.
final class SqliteActionStore implements ActionStore {
  SqliteActionStore({
    required ActionDatabase database,
    FeedDatabase? legacyFeedDatabase,
  }) : _database = database,
       _legacyFeedDatabase = legacyFeedDatabase;

  final ActionDatabase _database;
  final FeedDatabase? _legacyFeedDatabase;
  Future<Database>? _readyFuture;

  Future<Database> _readyDatabase() {
    final pending = _readyFuture;
    if (pending != null) return pending;
    final future = _openAndMigrate();
    _readyFuture = future;
    return future.catchError((Object error, StackTrace stack) {
      if (identical(_readyFuture, future)) {
        _readyFuture = null;
      }
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<Database> _openAndMigrate() async {
    final db = await _database.database;
    if (_legacyFeedDatabase case final legacy?) {
      await _migrateLegacyActions(db, legacy);
    }
    return db;
  }

  Future<void> _migrateLegacyActions(
    Database target,
    FeedDatabase legacy,
  ) async {
    final legacyDb = await legacy.database;
    final tables = await legacyDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [ActionDatabase.actionTable],
    );
    if (tables.isEmpty) return;

    final rows = await legacyDb.query(
      ActionDatabase.actionTable,
      orderBy: 'id ASC',
    );
    if (rows.isNotEmpty) {
      await target.transaction((txn) async {
        final seenCounts = <String, int>{};
        for (final row in rows) {
          final key = [
            row['owner'],
            row['type'],
            row['dedupe_key'],
            row['payload'],
            row['status'],
            row['attempt'],
            row['next_attempt_at'],
            row['created_at'],
          ].join('\u0000');
          final seenBefore = seenCounts[key] ?? 0;
          seenCounts[key] = seenBefore + 1;

          final nextAttemptAt = row['next_attempt_at'];
          final nextClause = nextAttemptAt == null
              ? 'next_attempt_at IS NULL'
              : 'next_attempt_at = ?';
          final existing = await txn.query(
            ActionDatabase.actionTable,
            columns: const ['id'],
            where:
                'owner = ? AND type = ? AND dedupe_key = ? AND '
                'payload = ? AND status = ? AND attempt = ? AND '
                '$nextClause AND created_at = ?',
            whereArgs: [
              row['owner'],
              row['type'],
              row['dedupe_key'],
              row['payload'],
              row['status'],
              row['attempt'],
              ?nextAttemptAt,
              row['created_at'],
            ],
          );
          if (existing.length <= seenBefore) {
            await txn.insert(ActionDatabase.actionTable, {
              'owner': row['owner'],
              'type': row['type'],
              'dedupe_key': row['dedupe_key'],
              'payload': row['payload'],
              'status': row['status'],
              'attempt': row['attempt'],
              'next_attempt_at': row['next_attempt_at'],
              'created_at': row['created_at'],
            });
          }
        }
      });
    }
    await legacyDb.execute(
      'DROP TABLE IF EXISTS ${ActionDatabase.actionTable}',
    );
  }

  @override
  Future<int> enqueue(StoredAction draft) async {
    final db = await _readyDatabase();
    return db.transaction((txn) async {
      await txn.delete(
        ActionDatabase.actionTable,
        where: 'owner = ? AND dedupe_key = ? AND status = ?',
        whereArgs: [draft.owner, draft.dedupeKey, ActionStatus.pending.dbValue],
      );
      return txn.insert(ActionDatabase.actionTable, _toRow(draft));
    });
  }

  @override
  Future<StoredAction?> nextReady(String owner, int nowMs) async {
    final db = await _readyDatabase();
    final rows = await db.query(
      ActionDatabase.actionTable,
      where:
          'owner = ? AND status = ? AND '
          '(next_attempt_at IS NULL OR next_attempt_at <= ?)',
      whereArgs: [owner, ActionStatus.pending.dbValue, nowMs],
      orderBy: 'id ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.single);
  }

  @override
  Future<bool> markRunning(int id) async {
    final db = await _readyDatabase();
    final claimed = await db.update(
      ActionDatabase.actionTable,
      {'status': ActionStatus.running.dbValue},
      where: 'id = ? AND status = ?',
      whereArgs: [id, ActionStatus.pending.dbValue],
    );
    return claimed > 0;
  }

  @override
  Future<void> markPending(int id, {int? attempt, int? nextAttemptAtMs}) async {
    final values = <String, Object?>{'status': ActionStatus.pending.dbValue};
    if (attempt != null) values['attempt'] = attempt;
    values['next_attempt_at'] = nextAttemptAtMs;
    await _update(id, values);
  }

  @override
  Future<void> markFailed(int id) => _update(id, {
    'status': ActionStatus.failed.dbValue,
    'next_attempt_at': null,
  });

  @override
  Future<void> delete(int id) async {
    final db = await _readyDatabase();
    await db.delete(
      ActionDatabase.actionTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<bool> deletePending(String owner, String dedupeKey) async {
    final db = await _readyDatabase();
    final deleted = await db.delete(
      ActionDatabase.actionTable,
      where: 'owner = ? AND dedupe_key = ? AND status = ?',
      whereArgs: [owner, dedupeKey, ActionStatus.pending.dbValue],
    );
    return deleted > 0;
  }

  @override
  Future<({int reset, int dropped})> recoverInterrupted() async {
    const table = ActionDatabase.actionTable;
    final running = ActionStatus.running.dbValue;
    final db = await _readyDatabase();
    return db.transaction((txn) async {
      final dropped = await txn.rawDelete(
        'DELETE FROM $table WHERE status = ? AND EXISTS ('
        'SELECT 1 FROM $table AS newer '
        'WHERE newer.owner = $table.owner '
        'AND newer.dedupe_key = $table.dedupe_key '
        'AND newer.status = ? AND newer.id > $table.id)',
        [running, ActionStatus.pending.dbValue],
      );
      final reset = await txn.update(
        table,
        {'status': ActionStatus.pending.dbValue},
        where: 'status = ?',
        whereArgs: [running],
      );
      return (reset: reset, dropped: dropped);
    });
  }

  @override
  Future<int?> nextPendingAt(String owner) async {
    final db = await _readyDatabase();
    final rows = await db.rawQuery(
      'SELECT MIN(COALESCE(next_attempt_at, 0)) AS due '
      'FROM ${ActionDatabase.actionTable} WHERE owner = ? AND status = ?',
      [owner, ActionStatus.pending.dbValue],
    );
    return rows.single['due'] as int?;
  }

  @override
  Future<List<StoredAction>> listFor(String owner) async {
    final db = await _readyDatabase();
    final rows = await db.query(
      ActionDatabase.actionTable,
      where: 'owner = ?',
      whereArgs: [owner],
      orderBy: 'id ASC',
    );
    return [for (final row in rows) _fromRow(row)];
  }

  @override
  Future<void> clearAccount(String owner) async {
    final db = await _readyDatabase();
    await db.delete(
      ActionDatabase.actionTable,
      where: 'owner = ?',
      whereArgs: [owner],
    );
  }

  Future<void> _update(int id, Map<String, Object?> values) async {
    final db = await _readyDatabase();
    await db.update(
      ActionDatabase.actionTable,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Map<String, Object?> _toRow(StoredAction draft) => {
    'owner': draft.owner,
    'type': draft.type,
    'dedupe_key': draft.dedupeKey,
    'payload': draft.payload,
    'status': draft.status.dbValue,
    'attempt': draft.attempt,
    'next_attempt_at': draft.nextAttemptAt,
    'created_at': draft.createdAt,
  };

  static StoredAction _fromRow(Map<String, Object?> row) {
    return StoredAction(
      id: row['id']! as int,
      owner: row['owner']! as String,
      type: row['type']! as String,
      dedupeKey: row['dedupe_key']! as String,
      payload: row['payload']! as String,
      status: ActionStatus.fromDb(row['status']! as String),
      attempt: row['attempt']! as int,
      nextAttemptAt: row['next_attempt_at'] as int?,
      createdAt: row['created_at']! as int,
    );
  }
}

/// In-memory store keeping the same coalesce/readiness semantics for tests.
@visibleForTesting
final class InMemoryActionStore implements ActionStore {
  InMemoryActionStore({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final List<StoredAction> _rows = [];
  int _nextId = 1;

  @override
  Future<int> enqueue(StoredAction draft) async {
    _rows.removeWhere(
      (row) =>
          row.owner == draft.owner &&
          row.dedupeKey == draft.dedupeKey &&
          row.status == ActionStatus.pending,
    );
    final row = StoredAction(
      id: _nextId++,
      owner: draft.owner,
      type: draft.type,
      dedupeKey: draft.dedupeKey,
      payload: draft.payload,
      status: ActionStatus.pending,
      attempt: 0,
      nextAttemptAt: null,
      createdAt: _now().millisecondsSinceEpoch,
    );
    _rows.add(row);
    return row.id;
  }

  @override
  Future<StoredAction?> nextReady(String owner, int nowMs) async {
    for (final row in _rows) {
      if (row.owner != owner || row.status != ActionStatus.pending) continue;
      final next = row.nextAttemptAt;
      if (next == null || next <= nowMs) return row;
    }
    return null;
  }

  @override
  Future<bool> markRunning(int id) async {
    final index = _rows.indexWhere(
      (row) => row.id == id && row.status == ActionStatus.pending,
    );
    if (index < 0) return false;
    _rows[index] = _rows[index].copyWith(status: ActionStatus.running);
    return true;
  }

  @override
  Future<void> markPending(int id, {int? attempt, int? nextAttemptAtMs}) =>
      _apply(
        id,
        (row) => row.copyWith(
          status: ActionStatus.pending,
          attempt: attempt,
          nextAttemptAt: nextAttemptAtMs,
          clearNextAttempt: nextAttemptAtMs == null,
        ),
      );

  @override
  Future<void> markFailed(int id) => _apply(
    id,
    (row) => row.copyWith(status: ActionStatus.failed, clearNextAttempt: true),
  );

  @override
  Future<void> delete(int id) async {
    _rows.removeWhere((row) => row.id == id);
  }

  @override
  Future<bool> deletePending(String owner, String dedupeKey) async {
    final before = _rows.length;
    _rows.removeWhere(
      (row) =>
          row.owner == owner &&
          row.dedupeKey == dedupeKey &&
          row.status == ActionStatus.pending,
    );
    return _rows.length < before;
  }

  @override
  Future<({int reset, int dropped})> recoverInterrupted() async {
    bool superseded(StoredAction stale) => _rows.any(
      (newer) =>
          newer.owner == stale.owner &&
          newer.dedupeKey == stale.dedupeKey &&
          newer.status == ActionStatus.pending &&
          newer.id > stale.id,
    );
    final before = _rows.length;
    _rows.removeWhere(
      (row) => row.status == ActionStatus.running && superseded(row),
    );
    var reset = 0;
    for (var i = 0; i < _rows.length; i++) {
      if (_rows[i].status != ActionStatus.running) continue;
      _rows[i] = _rows[i].copyWith(status: ActionStatus.pending);
      reset++;
    }
    return (reset: reset, dropped: before - _rows.length);
  }

  @override
  Future<int?> nextPendingAt(String owner) async {
    int? due;
    for (final row in _rows) {
      if (row.owner != owner || row.status != ActionStatus.pending) continue;
      final ready = row.nextAttemptAt ?? 0;
      if (due == null || ready < due) due = ready;
    }
    return due;
  }

  @override
  Future<List<StoredAction>> listFor(String owner) async => [
    for (final row in _rows)
      if (row.owner == owner) row,
  ];

  @override
  Future<void> clearAccount(String owner) async {
    _rows.removeWhere((row) => row.owner == owner);
  }

  Future<void> _apply(int id, StoredAction Function(StoredAction) map) async {
    for (var i = 0; i < _rows.length; i++) {
      if (_rows[i].id == id) {
        _rows[i] = map(_rows[i]);
        return;
      }
    }
  }
}
