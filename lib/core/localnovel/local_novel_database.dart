/// SQLite connection and schema owner for the local `local_novels.db`
/// database. Mirrors [FeedDatabase]/[WatchLaterDatabase]: the database owns
/// the lazy connection and factory choice; CRUD belongs to
/// [LocalNovelRepository]. See `backend/history.md`.
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Chooses the local-novels SQLite factory without reading [Platform].
@visibleForTesting
DatabaseFactory localNovelDatabaseFactory({required bool useMobileSqflite}) {
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

/// Owns the one SQLite connection used by the local-novel library index.
class LocalNovelDatabase {
  LocalNovelDatabase({DatabaseFactory? factory, String? databasePath})
    : _factory = factory ?? _platformDatabaseFactory(),
      _databasePath = databasePath;

  static const databaseName = 'local_novels.db';
  static const table = 'local_novels';
  static const schemaVersion = 1;

  final DatabaseFactory _factory;
  final String? _databasePath;
  Future<Database>? _databaseFuture;
  bool _closed = false;

  static DatabaseFactory _platformDatabaseFactory() {
    return localNovelDatabaseFactory(
      useMobileSqflite: Platform.isAndroid || Platform.isIOS,
    );
  }

  Future<Database> get database {
    if (_closed) {
      return Future<Database>.error(
        StateError('local novel database is closed'),
      );
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
        onCreate: (db, version) => _createSchema(db),
        onUpgrade: _upgrade,
        onDowngrade: _refuseDowngrade,
      ),
    );
  }

  Future<String> _defaultPath() async {
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      return sqflite.inMemoryDatabasePath;
    }
    return path.join(await _factory.getDatabasesPath(), databaseName);
  }

  Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $table (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        author TEXT,
        path TEXT NOT NULL UNIQUE,
        char_count INTEGER NOT NULL DEFAULT 0,
        imported_at INTEGER NOT NULL,
        read_offset INTEGER
      )
    ''');
  }

  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 1) {
      await _createSchema(db);
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
