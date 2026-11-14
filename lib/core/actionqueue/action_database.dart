/// SQLite connection and schema owner for the local `actions.db` database.
/// [ActionDatabase] owns the schema; connection lifecycle and factory choice
/// live in [SqliteDatabase], and queue operations belong to [SqliteActionStore].
/// See `backend/sqlite.md`.
library;

import 'package:sqflite/sqflite.dart';

import '../sqlite/sqlite_database.dart';

/// Owns the one SQLite connection used by offline action queue persistence.
///
/// The connection is opened lazily once and remains open until the Riverpod
/// container is disposed. A database left behind by a newer app build refuses
/// to open (`SqliteDatabase.refuseDowngrade`) rather than losing pending mutations.
class ActionDatabase {
  ActionDatabase({DatabaseFactory? factory, String? databasePath})
    : _sqlite = SqliteDatabase(
        databaseName: databaseName,
        schemaVersion: schemaVersion,
        closedMessage: 'action database is closed',
        factory: factory,
        databasePath: databasePath,
        onCreate: (db, _) => _createSchema(db),
        onUpgrade: _upgrade,
        onDowngrade: SqliteDatabase.refuseDowngrade(databaseName),
      );

  static const databaseName = 'actions.db';
  static const actionTable = 'action_queue';
  static const schemaVersion = 1;

  final SqliteDatabase _sqlite;

  /// The single connection future also serializes concurrent first access.
  Future<Database> get database => _sqlite.database;

  Future<void> close() => _sqlite.close();

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $actionTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        owner TEXT NOT NULL,
        type TEXT NOT NULL,
        dedupe_key TEXT NOT NULL,
        payload TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('pending','running','failed')),
        attempt INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX aq_ready
      ON $actionTable(owner, status, next_attempt_at)
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
