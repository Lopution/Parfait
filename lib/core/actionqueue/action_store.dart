/// Persistence boundary for the offline action queue. The sqflite
/// implementation lives on [FeedDatabase]; the in-memory variant keeps
/// engine tests free of sqlite. See `database-guidelines.md`.
library;

import 'package:meta/meta.dart';

import '../paging/feed_database.dart';
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

  Future<void> markRunning(int id);

  /// Returns a row to pending. [attempt] and [nextAttemptAtMs] carry the
  /// row-backoff schedule for row-scope retries; both stay null/unchanged
  /// for queue-scope cooldowns.
  Future<void> markPending(int id, {int? attempt, int? nextAttemptAtMs});

  /// Marks a row permanently failed after exhausting attempts.
  Future<void> markFailed(int id);

  /// Deletes a row — successful replay or explicit drop.
  Future<void> delete(int id);

  /// All rows of one owner, oldest first (tests/diagnostics).
  Future<List<StoredAction>> listFor(String owner);

  /// Drops every row of an account (logout/teardown boundary).
  Future<void> clearAccount(String owner);
}

/// SQLite-backed store over `feeds.db`'s `action_queue` table.
final class SqliteActionStore implements ActionStore {
  SqliteActionStore({required FeedDatabase database}) : _database = database;

  final FeedDatabase _database;

  @override
  Future<int> enqueue(StoredAction draft) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      await txn.delete(
        FeedDatabase.actionTable,
        where: 'owner = ? AND dedupe_key = ? AND status = ?',
        whereArgs: [draft.owner, draft.dedupeKey, ActionStatus.pending.dbValue],
      );
      return txn.insert(FeedDatabase.actionTable, _toRow(draft));
    });
  }

  @override
  Future<StoredAction?> nextReady(String owner, int nowMs) async {
    final db = await _database.database;
    final rows = await db.query(
      FeedDatabase.actionTable,
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
  Future<void> markRunning(int id) =>
      _update(id, {'status': ActionStatus.running.dbValue});

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
    final db = await _database.database;
    await db.delete(FeedDatabase.actionTable, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<List<StoredAction>> listFor(String owner) async {
    final db = await _database.database;
    final rows = await db.query(
      FeedDatabase.actionTable,
      where: 'owner = ?',
      whereArgs: [owner],
      orderBy: 'id ASC',
    );
    return [for (final row in rows) _fromRow(row)];
  }

  @override
  Future<void> clearAccount(String owner) async {
    final db = await _database.database;
    await db.delete(
      FeedDatabase.actionTable,
      where: 'owner = ?',
      whereArgs: [owner],
    );
  }

  Future<void> _update(int id, Map<String, Object?> values) async {
    final db = await _database.database;
    await db.update(
      FeedDatabase.actionTable,
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
  Future<void> markRunning(int id) =>
      _apply(id, (row) => row.copyWith(status: ActionStatus.running));

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
