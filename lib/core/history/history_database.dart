import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    if (Platform.isAndroid || Platform.isIOS) return sqflite.databaseFactory;
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }

  /// The single connection future also serializes concurrent first access.
  Future<Database> get database {
    if (_closed) {
      return Future<Database>.error(StateError('history database is closed'));
    }
    return _databaseFuture ??= _open();
  }

  Future<Database> _open() async {
    final databasePath =
        _databasePath ??
        path.join(await _factory.getDatabasesPath(), databaseName);
    return _factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) => _createSchema(db),
        onUpgrade: _upgrade,
      ),
    );
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
    if (newVersion > schemaVersion) {
      throw ArgumentError('unsupported history schema version $newVersion');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final future = _databaseFuture;
    if (future == null) return;
    final db = await future;
    if (db.isOpen) await db.close();
  }
}
