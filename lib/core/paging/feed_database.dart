/// SQLite connection and schema owner for the local `feeds.db` database.
/// [FeedDatabase] owns the schema; connection lifecycle and factory choice
/// live in [SqliteDatabase], and snapshot CRUD and eviction policy belong to
/// [FeedSnapshotStore]. See `backend/sqlite.md`.
library;

import 'package:sqflite/sqflite.dart';

import '../sqlite/sqlite_database.dart';

/// Owns the one SQLite connection used by feed snapshot persistence.
///
/// The connection is opened lazily once and remains open until the Riverpod
/// container is disposed. Tests can inject an FFI [DatabaseFactory] and a
/// temporary path without changing the production lifecycle.
class FeedDatabase {
  FeedDatabase({DatabaseFactory? factory, String? databasePath})
    : _sqlite = SqliteDatabase(
        databaseName: databaseName,
        schemaVersion: schemaVersion,
        closedMessage: 'feed database is closed',
        factory: factory,
        databasePath: databasePath,
        onCreate: (db, _) => _createSchema(db),
        onUpgrade: _upgrade,
        // A cache: a newer build's schema is dropped and created afresh
        // (a downgrade is a deliberate install). Queued offline actions live
        // in actions.db and are unaffected.
        onDowngrade: onDatabaseDowngradeDelete,
      );

  static const databaseName = 'feeds.db';
  static const snapshotTable = 'feed_snapshots';
  static const schemaVersion = 3;

  final SqliteDatabase _sqlite;

  /// The single connection future also serializes concurrent first access.
  Future<Database> get database => _sqlite.database;

  Future<void> close() => _sqlite.close();

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $snapshotTable (
        account_id TEXT NOT NULL,
        feed_key TEXT NOT NULL,
        ids TEXT NOT NULL,
        entities TEXT NOT NULL,
        cursor TEXT,
        saved_at INTEGER NOT NULL,
        snapshot_version INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (account_id, feed_key)
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
    // Keep any legacy v2 action_queue rows intact here; SqliteActionStore
    // migrates them into actions.db and drops the legacy table on first access.
  }
}
