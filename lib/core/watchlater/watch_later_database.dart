/// SQLite connection and schema owner for the local `watchlater.db`
/// database. [WatchLaterDatabase] owns the schema; connection lifecycle and
/// factory choice live in [SqliteDatabase], and CRUD belongs to
/// [WatchLaterRepository]. See `backend/sqlite.md`.
library;

import 'package:sqflite/sqflite.dart';

import '../sqlite/sqlite_database.dart';

/// Owns the one SQLite connection used by the watch-later feature.
///
/// The connection is opened lazily once and remains open until the Riverpod
/// container is disposed. Tests can inject an FFI [DatabaseFactory] and a
/// temporary path without changing the production lifecycle.
class WatchLaterDatabase {
  WatchLaterDatabase({DatabaseFactory? factory, String? databasePath})
    : _sqlite = SqliteDatabase(
        databaseName: databaseName,
        schemaVersion: schemaVersion,
        closedMessage: 'watch-later database is closed',
        factory: factory,
        databasePath: databasePath,
        onCreate: (db, _) => _createSchema(db),
        onUpgrade: _upgrade,
        onDowngrade: SqliteDatabase.refuseDowngrade(databaseName),
      );

  static const databaseName = 'watchlater.db';
  static const table = 'watch_later_entries';
  static const schemaVersion = 1;

  final SqliteDatabase _sqlite;

  /// The single connection future also serializes concurrent first access.
  Future<Database> get database => _sqlite.database;

  Future<void> close() => _sqlite.close();

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $table (
        account_id TEXT NOT NULL,
        illust_id INTEGER NOT NULL,
        added_at INTEGER NOT NULL,
        payload TEXT NOT NULL,
        PRIMARY KEY (account_id, illust_id)
      )
    ''');
    await db.execute('''
      CREATE INDEX ${table}_order
      ON $table (account_id, added_at DESC)
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
