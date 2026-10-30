/// SQLite connection and schema owner for the local `history.db` database.
/// [HistoryDatabase] owns the lazy connection and factory choice; CRUD and
/// outbox behavior belongs to [HistoryRepository]. See `backend/history.md`.
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Chooses the history SQLite factory without reading [Platform].
///
/// Production calls this with `useMobileSqflite: Platform.isAndroid ||
/// Platform.isIOS`. Tests pass the flag directly because `flutter test`
/// always reports a desktop [Platform].
@visibleForTesting
DatabaseFactory historyDatabaseFactory({required bool useMobileSqflite}) {
  if (useMobileSqflite) return sqflite.databaseFactory;
  sqfliteFfiInit();
  // The isolate-backed factory's port replies never reach the fake-async
  // zone of `testWidgets`; the no-isolate variant answers through
  // microtasks that `tester.pump` flushes (same rationale as feeds.db).
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return databaseFactoryFfiNoIsolate;
  }
  return databaseFactoryFfi;
}

/// Owns the one SQLite connection used by the history feature.
///
/// The connection is opened lazily once and remains open until the Riverpod
/// container is disposed. Tests can inject an FFI [DatabaseFactory] and a
/// temporary path without changing the production lifecycle.
class HistoryDatabase {
  HistoryDatabase({DatabaseFactory? factory, String? databasePath})
    : _factory = factory ?? _platformDatabaseFactory(),
      _databasePath = databasePath;

  static const databaseName = 'history.db';
  static const historyTable = 'history_records';
  static const outboxTable = 'pixiv_history_outbox';
  static const schemaVersion = 2;

  final DatabaseFactory _factory;
  final String? _databasePath;
  Future<Database>? _databaseFuture;
  bool _closed = false;

  static DatabaseFactory _platformDatabaseFactory() {
    return historyDatabaseFactory(
      useMobileSqflite: Platform.isAndroid || Platform.isIOS,
    );
  }

  /// The single connection future also serializes concurrent first access.
  Future<Database> get database {
    if (_closed) {
      return Future<Database>.error(StateError('history database is closed'));
    }
    return _databaseFuture ??= _open();
  }

  Future<Database> _open() async {
    final databasePath = _databasePath ?? await _defaultPath();
    return _factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        // The factory hands every opener of a path the same database,
        // `:memory:` included; each in-memory database must be its own.
        singleInstance: databasePath != sqflite.inMemoryDatabasePath,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) => _createSchema(db),
        onUpgrade: _upgrade,
        onDowngrade: _refuseDowngrade,
      ),
    );
  }

  /// Under `flutter test` each database is in memory: one a page opens in
  /// a widget test leaves no file in the test file's databases directory
  /// and no rows for the next case. Production resolves the real path.
  Future<String> _defaultPath() async {
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      return sqflite.inMemoryDatabasePath;
    }
    return path.join(await _factory.getDatabasesPath(), databaseName);
  }

  Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $historyTable (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        account_id TEXT NOT NULL,
        content_type TEXT NOT NULL CHECK (content_type IN ('illust', 'novel')),
        content_id INTEGER NOT NULL,
        last_viewed_at INTEGER NOT NULL,
        title TEXT NOT NULL,
        author_name TEXT NOT NULL,
        author_id INTEGER,
        cover_url TEXT,
        content_version TEXT,
        anchor_paragraph_id TEXT,
        anchor_offset INTEGER,
        visible_duration_ms INTEGER NOT NULL DEFAULT 0,
        snapshot_version INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX ${historyTable}_identity
      ON $historyTable (account_id, content_type, content_id)
    ''');
    await db.execute('''
      CREATE INDEX ${historyTable}_order
      ON $historyTable (account_id, last_viewed_at DESC, id DESC)
    ''');
    await db.execute('''
      CREATE TABLE $outboxTable (
        account_id TEXT NOT NULL,
        content_type TEXT NOT NULL CHECK (content_type = 'illust'),
        content_id INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        last_viewed_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER,
        PRIMARY KEY (account_id, content_type, content_id)
      )
    ''');
    await db.execute('''
      CREATE INDEX ${outboxTable}_ready
      ON $outboxTable (account_id, next_attempt_at, last_viewed_at)
    ''');
  }

  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    // Version 1 already had the compact history and outbox tables. Version 2
    // adds an explicit snapshot format marker so future readers can migrate a
    // row without storing the original Pixiv JSON.
    if (oldVersion < 1) {
      await _createSchema(db);
      return;
    }
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE $historyTable '
        'ADD COLUMN snapshot_version INTEGER NOT NULL DEFAULT 1',
      );
    }
  }

  /// A newer build's schema is left alone: lowering the version would make
  /// that build re-run a migration it already ran, and the database would
  /// stop opening. The feature reports the failed open instead.
  static Future<void> _refuseDowngrade(Database db, int from, int to) {
    throw StateError(
      '$databaseName is schema $from; this build reads up to $to',
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final future = _databaseFuture;
    if (future == null) return;
    final Database db;
    try {
      db = await future;
    } on Object {
      // The open failed (a newer schema): nothing to close.
      return;
    }
    if (db.isOpen) await db.close();
  }
}
