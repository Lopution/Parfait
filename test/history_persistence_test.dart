import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:parfait/core/history/history_database.dart';
import 'package:parfait/core/history/history_models.dart';
import 'package:parfait/core/history/history_repository.dart';
import 'package:parfait/core/history/history_tracker.dart';
import 'package:parfait/core/network/api_error.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('HistoryRepository', () {
    late Directory directory;
    late HistoryDatabase database;
    late HistoryRepository repository;
    late DateTime now;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('pixiv-history-test-');
      database = HistoryDatabase(
        factory: databaseFactoryFfi,
        databasePath: path.join(directory.path, 'history.db'),
      );
      now = DateTime.utc(2026, 8, 27, 12);
      repository = HistoryRepository(database: database, now: () => now);
    });

    tearDown(() async {
      await database.close();
      await directory.delete(recursive: true);
    });

    test('opens one versioned schema and upgrades v1 rows', () async {
      final databasePath = path.join(directory.path, 'history.db');
      final legacy = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: sqflite.OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE history_records (
                id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                content_type TEXT NOT NULL,
                content_id INTEGER NOT NULL,
                last_viewed_at INTEGER NOT NULL,
                title TEXT NOT NULL,
                author_name TEXT NOT NULL,
                author_id INTEGER,
                cover_url TEXT,
                content_version TEXT,
                anchor_paragraph_id TEXT,
                anchor_offset INTEGER,
                visible_duration_ms INTEGER NOT NULL DEFAULT 0
              )
            ''');
            await db.execute(
              'CREATE UNIQUE INDEX history_records_identity ON '
              'history_records(account_id, content_type, content_id)',
            );
            await db.execute('''
              CREATE TABLE pixiv_history_outbox (
                account_id TEXT NOT NULL,
                content_type TEXT NOT NULL,
                content_id INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL DEFAULT 0,
                last_viewed_at INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_at INTEGER,
                PRIMARY KEY(account_id, content_type, content_id)
              )
            ''');
          },
        ),
      );
      await legacy.close();

      final opened = await database.database;
      final columns = await opened.rawQuery(
        'PRAGMA table_info(${HistoryDatabase.historyTable})',
      );
      expect(columns.any((row) => row['name'] == 'snapshot_version'), isTrue);
      final version = await opened.rawQuery('PRAGMA user_version');
      expect((version.single['user_version'] as num).toInt(), 2);
    });

    test('upserts, orders and isolates records by account', () async {
      await repository.upsert(_record('a', HistoryContentType.illust, 1));
      await repository.upsert(
        _record(
          'a',
          HistoryContentType.novel,
          2,
          viewedAt: DateTime.utc(2026, 8, 27, 12, 1),
        ),
      );
      await repository.upsert(_record('b', HistoryContentType.illust, 3));

      final page = await repository.page(accountId: 'a', limit: 1);
      expect(page.total, 2);
      expect(page.records.single.contentId, 2);
      expect(page.hasMore, isTrue);
      expect(await repository.count(accountId: 'b'), 1);

      await repository.upsert(
        _record(
          'a',
          HistoryContentType.illust,
          1,
          viewedAt: DateTime.utc(2026, 8, 27, 12, 2),
        ),
      );
      expect((await repository.page(accountId: 'a')).total, 2);
      expect(
        (await repository.page(accountId: 'a')).records.first.contentId,
        1,
      );
    });

    test('history read plans use indexes instead of table scans', () async {
      await repository.upsert(_record('a', HistoryContentType.illust, 1));
      await repository.commitView(
        record: _record('a', HistoryContentType.illust, 2),
        writeLocal: false,
        enqueuePixiv: true,
        unsubmittedPixivDuration: const Duration(seconds: 10),
      );
      final db = await database.database;

      Future<List<String>> explain(
        String sql, [
        List<Object?> args = const [],
      ]) async {
        final rows = await db.rawQuery('EXPLAIN QUERY PLAN $sql', args);
        return [for (final row in rows) row['detail']! as String];
      }

      final pagePlan = await explain(
        'SELECT * FROM ${HistoryDatabase.historyTable} '
        'WHERE account_id = ? '
        'ORDER BY last_viewed_at DESC, id DESC LIMIT 30 OFFSET 0',
        ['a'],
      );
      final countPlan = await explain(
        'SELECT COUNT(*) FROM ${HistoryDatabase.historyTable} '
        'WHERE account_id = ?',
        ['a'],
      );
      final findPlan = await explain(
        'SELECT * FROM ${HistoryDatabase.historyTable} '
        'WHERE account_id = ? AND content_type = ? AND content_id = ? '
        'LIMIT 1',
        ['a', HistoryContentType.illust.storageValue, 1],
      );
      final outboxPlan = await explain(
        'SELECT * FROM ${HistoryDatabase.outboxTable} '
        'WHERE account_id = ? AND '
        '(next_attempt_at IS NULL OR next_attempt_at <= ?) '
        'ORDER BY last_viewed_at ASC LIMIT 10',
        ['a', now.microsecondsSinceEpoch],
      );

      expect(pagePlan.join('\n'), contains('history_records_order'));
      expect(countPlan.join('\n'), contains('history_records_order'));
      expect(findPlan.join('\n'), contains('history_records_identity'));
      expect(outboxPlan.join('\n'), contains('pixiv_history_outbox_ready'));
      for (final detail in [
        ...pagePlan,
        ...countPlan,
        ...findPlan,
        ...outboxPlan,
      ]) {
        expect(detail.toUpperCase(), isNot(contains('SCAN TABLE')));
      }
    });

    test(
      'deletes one typed record without crossing account boundaries',
      () async {
        await repository.upsert(_record('a', HistoryContentType.illust, 1));
        await repository.upsert(_record('a', HistoryContentType.novel, 2));
        await repository.upsert(_record('b', HistoryContentType.illust, 1));

        expect(
          await repository.delete(
            accountId: 'a',
            contentType: HistoryContentType.illust,
            contentId: 1,
          ),
          1,
        );
        expect(
          await repository.find(
            accountId: 'a',
            contentType: HistoryContentType.illust,
            contentId: 1,
          ),
          isNull,
        );
        expect(await repository.count(accountId: 'a'), 1);
        expect(await repository.count(accountId: 'b'), 1);
      },
    );

    test('commits local row and merged outbox duration atomically', () async {
      final record = _record('a', HistoryContentType.illust, 42);
      await repository.commitView(
        record: record,
        writeLocal: true,
        enqueuePixiv: true,
        unsubmittedPixivDuration: const Duration(seconds: 10),
      );
      await repository.commitView(
        record: record.copyWith(
          lastViewedAt: DateTime.utc(2026, 8, 27, 12, 2),
          visibleDuration: const Duration(seconds: 14),
        ),
        writeLocal: true,
        enqueuePixiv: true,
        unsubmittedPixivDuration: const Duration(seconds: 4),
      );

      final pending = await repository.pendingOutbox(accountId: 'a');
      expect(pending, hasLength(1));
      expect(pending.single.unsubmittedDuration, const Duration(seconds: 14));
      expect(
        (await repository.find(
          accountId: 'a',
          contentType: HistoryContentType.illust,
          contentId: 42,
        ))!.visibleDuration,
        const Duration(seconds: 14),
      );
    });

    test('flushes successful work and retains failures with backoff', () async {
      await repository.commitView(
        record: _record('a', HistoryContentType.illust, 1),
        writeLocal: false,
        enqueuePixiv: true,
        unsubmittedPixivDuration: const Duration(seconds: 10),
      );
      final remote = _FakeRemote()..shouldFail = true;
      await expectLater(
        repository.flushOutbox(accountId: 'a', remote: remote),
        throwsA(isA<HistorySyncException>()),
      );
      expect(remote.calls, [1]);
      expect(
        await repository.pendingOutbox(
          accountId: 'a',
          now: DateTime.utc(2026, 8, 27, 12),
        ),
        isEmpty,
      );

      remote.shouldFail = false;
      now = now.add(const Duration(seconds: 2));
      await repository.flushOutbox(accountId: 'a', remote: remote);
      expect(remote.calls, [1, 1]);
      expect(await repository.pendingOutbox(accountId: 'a'), isEmpty);
    });

    test('a server error waits out its backoff without a report', () async {
      await repository.commitView(
        record: _record('a', HistoryContentType.illust, 1),
        writeLocal: false,
        enqueuePixiv: true,
        unsubmittedPixivDuration: const Duration(seconds: 10),
      );
      final remote = _FakeRemote()
        ..shouldFail = true
        ..failure = const ApiHttpError(503);
      await repository.flushOutbox(accountId: 'a', remote: remote);
      expect(remote.calls, [1]);
      expect(await repository.pendingOutbox(accountId: 'a'), isEmpty);
      now = now.add(const Duration(seconds: 2));
      expect(await repository.pendingOutbox(accountId: 'a'), hasLength(1));
    });

    test('surfaces a corrupt row instead of fabricating history', () async {
      final db = await database.database;
      await db.execute('PRAGMA ignore_check_constraints = ON');
      await db.insert(HistoryDatabase.historyTable, {
        'account_id': 'a',
        'content_type': 'corrupted',
        'content_id': 1,
        'last_viewed_at': now.microsecondsSinceEpoch,
        'title': 'bad row',
        'author_name': 'bad author',
        'visible_duration_ms': 0,
        'snapshot_version': 1,
      });

      await expectLater(
        repository.page(accountId: 'a'),
        throwsA(isA<FormatException>()),
      );
    });

    test('announces writes to the local rows, not to the outbox', () async {
      var changes = 0;
      final subscription = repository.changes.listen((_) => changes++);
      addTearDown(subscription.cancel);
      Future<int> announced() async {
        await pumpEventQueue();
        return changes;
      }

      final record = _record('a', HistoryContentType.illust, 1);
      await repository.upsert(record);
      expect(await announced(), 1);

      await repository.commitView(
        record: record,
        writeLocal: false,
        enqueuePixiv: true,
        unsubmittedPixivDuration: const Duration(seconds: 10),
      );
      await repository.clearOutbox('a');
      await repository.delete(
        accountId: 'a',
        contentType: HistoryContentType.novel,
        contentId: 1,
      );
      expect(await announced(), 1, reason: 'no row changed');

      await repository.commitView(
        record: record,
        writeLocal: true,
        enqueuePixiv: false,
        unsubmittedPixivDuration: Duration.zero,
      );
      await repository.delete(
        accountId: 'a',
        contentType: HistoryContentType.illust,
        contentId: 1,
      );
      await repository.clear('a');
      expect(await announced(), 4);
    });

    test('clear removes only the selected account and its outbox', () async {
      for (final account in ['a', 'b']) {
        await repository.commitView(
          record: _record(account, HistoryContentType.illust, 1),
          writeLocal: true,
          enqueuePixiv: true,
          unsubmittedPixivDuration: const Duration(seconds: 10),
        );
      }
      await repository.clear('a');
      expect(await repository.count(accountId: 'a'), 0);
      expect(await repository.count(accountId: 'b'), 1);
      expect(await repository.pendingOutbox(accountId: 'a'), isEmpty);
      expect(await repository.pendingOutbox(accountId: 'b'), hasLength(1));
    });
  });

  test(
    'HistoryTracker counts only elapsed visible segments and no timer',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pixiv-history-tracker-',
      );
      final database = HistoryDatabase(
        factory: databaseFactoryFfi,
        databasePath: path.join(directory.path, 'history.db'),
      );
      addTearDown(() async {
        await database.close();
        await directory.delete(recursive: true);
      });
      final repository = HistoryRepository(
        database: database,
        now: () => DateTime.utc(2026, 8, 27, 12),
      );
      final clock = _ManualClock();
      final tracker = HistoryTracker(
        repository: repository,
        accountId: 'a',
        contentType: HistoryContentType.illust,
        contentId: 7,
        snapshot: const HistorySnapshot(title: 'work', authorName: 'artist'),
        localHistoryEnabled: true,
        pixivHistoryEnabled: true,
        clock: clock,
      );

      await tracker.start();
      clock.advance(const Duration(seconds: 3));
      await tracker.pauseAndCommit();
      await tracker.start();
      clock.advance(const Duration(seconds: 8));
      await tracker.finish();

      final record = await repository.find(
        accountId: 'a',
        contentType: HistoryContentType.illust,
        contentId: 7,
      );
      expect(record!.visibleDuration, const Duration(seconds: 11));
      expect(
        (await repository.pendingOutbox(
          accountId: 'a',
        )).single.unsubmittedDuration,
        const Duration(seconds: 11),
      );
    },
  );

  group('database factory', () {
    test('mobile factory is sqflite.databaseFactory, not FFI', () {
      // `flutter test` runs on Linux: the Android/iOS plugin never registers
      // the default factory, so `sqflite.databaseFactory` throws until set.
      // Install the same plugin instance Android would, then restore.
      final previous = sqflite.databaseFactoryOrNull;
      addTearDown(() => sqflite.databaseFactory = previous);
      sqflite.databaseFactory = sqflite.databaseFactorySqflitePlugin;

      final factory = historyDatabaseFactory(useMobileSqflite: true);
      expect(identical(factory, sqflite.databaseFactory), isTrue);
      expect(identical(factory, sqflite.databaseFactorySqflitePlugin), isTrue);
      expect(identical(factory, databaseFactoryFfi), isFalse);
    });
  });
}

HistoryRecord _record(
  String accountId,
  HistoryContentType contentType,
  int contentId, {
  DateTime? viewedAt,
}) {
  return HistoryRecord(
    accountId: accountId,
    contentType: contentType,
    contentId: contentId,
    lastViewedAt: viewedAt ?? DateTime.utc(2026, 8, 27, 12),
    snapshot: const HistorySnapshot(
      title: 'title',
      authorName: 'author',
      coverUrl: 'https://i.pximg.net/cover.jpg',
    ),
  );
}

class _FakeRemote implements PixivHistoryRemote {
  final List<int> calls = [];
  bool shouldFail = false;
  Object failure = StateError('rejected');

  @override
  Future<void> addIllust(int illustId) async {
    calls.add(illustId);
    if (shouldFail) throw failure;
  }
}

class _ManualClock implements HistoryElapsedClock {
  Duration _elapsed = Duration.zero;
  bool _running = false;

  void advance(Duration duration) {
    if (_running) _elapsed += duration;
  }

  @override
  Duration get elapsed => _elapsed;

  @override
  void start() => _running = true;

  @override
  void stop() => _running = false;

  @override
  void reset() => _elapsed = Duration.zero;
}
