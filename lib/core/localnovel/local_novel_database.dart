/// SQLite connection and schema owner for the local `local_novels.db`
/// database. [LocalNovelDatabase] owns the schema; connection lifecycle and
/// factory choice live in [SqliteDatabase], and CRUD belongs to
/// [LocalNovelRepository]. See `backend/history.md`.
library;

import 'package:sqflite/sqflite.dart';

import '../sqlite/sqlite_database.dart';

/// Owns the one SQLite connection used by the local-novel library index.
class LocalNovelDatabase {
  LocalNovelDatabase({DatabaseFactory? factory, String? databasePath})
    : _sqlite = SqliteDatabase(
        databaseName: databaseName,
        schemaVersion: schemaVersion,
        closedMessage: 'local novel database is closed',
        factory: factory,
        databasePath: databasePath,
        onCreate: (db, _) => _createSchema(db),
        onUpgrade: _upgrade,
        onDowngrade: SqliteDatabase.refuseDowngrade(databaseName),
      );

  static const databaseName = 'local_novels.db';
  static const table = 'local_novels';
  static const schemaVersion = 1;

  final SqliteDatabase _sqlite;

  Future<Database> get database => _sqlite.database;

  Future<void> close() => _sqlite.close();

  static Future<void> _createSchema(DatabaseExecutor db) async {
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

  static Future<void> _upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 1) {
      await _createSchema(db);
    }
  }
}
