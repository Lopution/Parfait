import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../auth/account_store.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'history_database.dart';
import 'history_models.dart';

/// Remote side of the Pixiv browsing-history outbox.
abstract interface class PixivHistoryRemote {
  Future<void> addIllust(int illustId);
}

class PixivApiHistoryRemote implements PixivHistoryRemote {
  PixivApiHistoryRemote(this._client);

  final PixivHttpClient _client;

  @override
  Future<void> addIllust(int illustId) async {
    if (illustId <= 0) throw ArgumentError.value(illustId, 'illustId');
    await _client.post(
      PixivClientIdentity.appApiBase.replace(
        path: '/v2/user/browsing-history/illust/add',
      ),
      body: {'illust_ids[]': '$illustId'},
    );
  }
}

/// Typed CRUD boundary for the compact history schema.
class HistoryRepository {
  HistoryRepository({
    required HistoryDatabase database,
    DateTime Function()? now,
  }) : _database = database,
       _now = now ?? DateTime.now;

  static const defaultPageSize = 30;
  static const pixivMinimumDuration = Duration(seconds: 10);

  final HistoryDatabase _database;
  final DateTime Function() _now;
  Future<void> _flushTail = Future<void>.value();

  Future<void> upsert(HistoryRecord record) async {
    _validateRecord(record);
    final db = await _database.database;
    await db.insert(
      HistoryDatabase.historyTable,
      record.toColumns(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<HistoryPageResult> page({
    required String accountId,
    HistoryContentType? contentType,
    int offset = 0,
    int limit = defaultPageSize,
  }) async {
    _validateAccount(accountId);
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 100');
    }
    final db = await _database.database;
    final where = StringBuffer('account_id = ?');
    final whereArgs = <Object?>[accountId];
    if (contentType != null) {
      where.write(' AND content_type = ?');
      whereArgs.add(contentType.storageValue);
    }
    final rows = await db.query(
      HistoryDatabase.historyTable,
      columns: _historyColumns,
      where: where.toString(),
      whereArgs: whereArgs,
      orderBy: 'last_viewed_at DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    final countRows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM ${HistoryDatabase.historyTable} '
      'WHERE ${where.toString()}',
      whereArgs,
    );
    final total = (countRows.single['count'] as num).toInt();
    return HistoryPageResult(
      records: [for (final row in rows) HistoryRecord.fromRow(row)],
      total: total,
      offset: offset,
      limit: limit,
    );
  }

  Future<HistoryRecord?> find({
    required String accountId,
    required HistoryContentType contentType,
    required int contentId,
  }) async {
    _validateAccount(accountId);
    _validateContentId(contentId);
    final db = await _database.database;
    final rows = await db.query(
      HistoryDatabase.historyTable,
      columns: _historyColumns,
      where: 'account_id = ? AND content_type = ? AND content_id = ?',
      whereArgs: [accountId, contentType.storageValue, contentId],
      limit: 1,
    );
    return rows.isEmpty ? null : HistoryRecord.fromRow(rows.single);
  }

  Future<int> count({
    required String accountId,
    HistoryContentType? contentType,
  }) async {
    final result = await page(
      accountId: accountId,
      contentType: contentType,
      offset: 0,
      limit: 1,
    );
    return result.total;
  }

  Future<int> delete({
    required String accountId,
    required HistoryContentType contentType,
    required int contentId,
  }) async {
    _validateAccount(accountId);
    _validateContentId(contentId);
    final db = await _database.database;
    return db.delete(
      HistoryDatabase.historyTable,
      where: 'account_id = ? AND content_type = ? AND content_id = ?',
      whereArgs: [accountId, contentType.storageValue, contentId],
    );
  }

  /// Clears local rows and their not-yet-submitted remote work for one account.
  Future<void> clear(String accountId) async {
    _validateAccount(accountId);
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete(
        HistoryDatabase.historyTable,
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
      await txn.delete(
        HistoryDatabase.outboxTable,
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
    });
  }

  /// Commits one visibility snapshot and (optionally) the newly observed
  /// duration in one SQLite transaction.
  Future<void> commitView({
    required HistoryRecord record,
    required bool writeLocal,
    required bool enqueuePixiv,
    required Duration unsubmittedPixivDuration,
  }) async {
    _validateRecord(record);
    if (unsubmittedPixivDuration.isNegative) {
      throw ArgumentError.value(
        unsubmittedPixivDuration,
        'unsubmittedPixivDuration',
      );
    }
    if (!writeLocal && !enqueuePixiv) return;
    if (enqueuePixiv && record.contentType != HistoryContentType.illust) {
      throw ArgumentError('Pixiv history only supports illust content');
    }
    final db = await _database.database;
    await db.transaction((txn) async {
      if (writeLocal) {
        await txn.insert(
          HistoryDatabase.historyTable,
          record.toColumns(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      if (enqueuePixiv && unsubmittedPixivDuration > Duration.zero) {
        await _enqueuePixiv(
          txn,
          accountId: record.accountId,
          contentId: record.contentId,
          lastViewedAt: record.lastViewedAt,
          duration: unsubmittedPixivDuration,
        );
      }
    });
  }

  Future<List<PixivHistoryOutboxEntry>> pendingOutbox({
    required String accountId,
    int limit = 10,
    DateTime? now,
  }) async {
    _validateAccount(accountId);
    if (limit < 1 || limit > 50) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 50');
    }
    final timestamp = (now ?? _now()).toUtc().microsecondsSinceEpoch;
    final db = await _database.database;
    final rows = await db.query(
      HistoryDatabase.outboxTable,
      where:
          'account_id = ? AND '
          '(next_attempt_at IS NULL OR next_attempt_at <= ?)',
      whereArgs: [accountId, timestamp],
      orderBy: 'last_viewed_at ASC',
      limit: limit,
    );
    return [for (final row in rows) PixivHistoryOutboxEntry.fromRow(row)];
  }

  /// Flushes one account serially. Failures remain in the outbox with bounded
  /// backoff and are surfaced to the caller; they are never converted to a
  /// false success.
  Future<void> flushOutbox({
    required String accountId,
    required PixivHistoryRemote remote,
    bool Function()? isAccountCurrent,
    int limit = 10,
  }) {
    _validateAccount(accountId);
    final operation = _flushTail.then<void>(
      (_) => _flushOutbox(
        accountId: accountId,
        remote: remote,
        isAccountCurrent: isAccountCurrent,
        limit: limit,
      ),
    );
    _flushTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _flushOutbox({
    required String accountId,
    required PixivHistoryRemote remote,
    required bool Function()? isAccountCurrent,
    required int limit,
  }) async {
    final entries = await pendingOutbox(accountId: accountId, limit: limit);
    final failures = <Object>[];
    for (final entry in entries) {
      if (isAccountCurrent != null && !isAccountCurrent()) {
        throw HistoryAccountChangedException(accountId);
      }
      try {
        await remote.addIllust(entry.contentId);
        await _deleteOutbox(entry);
      } on Object catch (error) {
        failures.add(error);
        try {
          await _recordOutboxFailure(entry);
        } on Object catch (recordError) {
          failures.add(recordError);
        }
      }
    }
    if (failures.isNotEmpty) throw HistorySyncException(failures);
  }

  Future<void> _deleteOutbox(PixivHistoryOutboxEntry entry) async {
    final db = await _database.database;
    await db.delete(
      HistoryDatabase.outboxTable,
      where: 'account_id = ? AND content_type = ? AND content_id = ?',
      whereArgs: [
        entry.accountId,
        entry.contentType.storageValue,
        entry.contentId,
      ],
    );
  }

  Future<void> _recordOutboxFailure(PixivHistoryOutboxEntry entry) async {
    final attempts = entry.attempts + 1;
    final delay = attempts >= 3
        ? const Duration(hours: 1)
        : Duration(seconds: 1 << (attempts - 1));
    final nextAttempt = _now().toUtc().add(delay).microsecondsSinceEpoch;
    final db = await _database.database;
    await db.update(
      HistoryDatabase.outboxTable,
      {'attempts': attempts, 'next_attempt_at': nextAttempt},
      where: 'account_id = ? AND content_type = ? AND content_id = ?',
      whereArgs: [
        entry.accountId,
        entry.contentType.storageValue,
        entry.contentId,
      ],
    );
  }

  Future<void> _enqueuePixiv(
    DatabaseExecutor db, {
    required String accountId,
    required int contentId,
    required DateTime lastViewedAt,
    required Duration duration,
  }) async {
    await db.rawInsert(
      'INSERT INTO ${HistoryDatabase.outboxTable} '
      '(account_id, content_type, content_id, duration_ms, last_viewed_at, '
      'attempts, next_attempt_at) VALUES (?, ?, ?, ?, ?, 0, NULL) '
      'ON CONFLICT(account_id, content_type, content_id) DO UPDATE SET '
      'duration_ms = duration_ms + excluded.duration_ms, '
      'last_viewed_at = excluded.last_viewed_at, attempts = 0, '
      'next_attempt_at = NULL',
      [
        accountId,
        HistoryContentType.illust.storageValue,
        contentId,
        duration.inMilliseconds,
        lastViewedAt.toUtc().microsecondsSinceEpoch,
      ],
    );
  }

  void _validateRecord(HistoryRecord record) {
    _validateAccount(record.accountId);
    _validateContentId(record.contentId);
    if (record.snapshotVersion < 1) {
      throw ArgumentError.value(record.snapshotVersion, 'snapshotVersion');
    }
  }

  static void _validateAccount(String accountId) {
    if (accountId.trim().isEmpty) {
      throw ArgumentError.value(accountId, 'accountId');
    }
  }

  static void _validateContentId(int contentId) {
    if (contentId <= 0) throw ArgumentError.value(contentId, 'contentId');
  }

  static const _historyColumns = [
    'id AS row_id',
    'account_id',
    'content_type',
    'content_id',
    'last_viewed_at',
    'title',
    'author_name',
    'author_id',
    'cover_url',
    'content_version',
    'anchor_paragraph_id',
    'anchor_offset',
    'visible_duration_ms',
    'snapshot_version',
  ];
}

final historyDatabaseProvider = Provider<HistoryDatabase>((ref) {
  final database = HistoryDatabase();
  ref.onDispose(() => unawaited(database.close()));
  return database;
});

final historyRepositoryProvider = Provider<HistoryRepository>((ref) {
  return HistoryRepository(database: ref.watch(historyDatabaseProvider));
});

final pixivHistoryRemoteProvider = Provider<PixivHistoryRemote>((ref) {
  return PixivApiHistoryRemote(ref.watch(pixivHttpClientProvider));
});

final historyAccountIdProvider = Provider<String?>((ref) {
  return ref.watch(
    accountStoreProvider.select((async) => async.value?.usableCurrent?.id),
  );
});
