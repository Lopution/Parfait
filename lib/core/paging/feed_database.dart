/// SQLite connection and schema owner for the local `feeds.db` database.
/// [FeedDatabase] owns the lazy connection and factory choice; snapshot CRUD
/// and eviction policy belongs to [FeedSnapshotStore]. Mirrors the
/// [HistoryDatabase] pattern — see `database-guidelines.md`.
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Chooses the feeds SQLite factory without reading [Platform].
///
/// Production calls this with `useMobileSqflite: Platform.isAndroid ||
/// Platform.isIOS`. Tests pass the flag directly because `flutter test`
/// always reports a desktop [Platform].
@visibleForTesting
DatabaseFactory feedDatabaseFactory({required bool useMobileSqflite}) {
  if (useMobileSqflite) return sqflite.databaseFactory;
  sqfliteFfiInit();
  return databaseFactoryFfi;
}

/// Owns the one SQLite connection used by feed snapshot persistence.
///
/// The connection is opened lazily once and remains open until the Riverpod
/// container is disposed. Tests can inject an FFI [DatabaseFactory] and a
/// temporary path without changing the production lifecycle.
class FeedDatabase {
  FeedDatabase({DatabaseFactory? factory, String? databasePath})
    : _factory = factory ?? _platformDatabaseFactory(),
      _databasePath = databasePath;

  static const databaseName = 'feeds.db';
  static const snapshotTable = 'feed_snapshots';
  static const schemaVersion = 1;

  final DatabaseFactory _factory;
  final String? _databasePath;
  Future<Database>? _databaseFuture;
  bool _closed = false;

  static DatabaseFactory _platformDatabaseFactory() {
    return feedDatabaseFactory(
      useMobileSqflite: Platform.isAndroid || Platform.isIOS,
    );
  }

  /// The single connection future also serializes concurrent first access.
  Future<Database> get database {
    if (_closed) {
      return Future<Database>.error(StateError('feed database is closed'));
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
        onCreate: (db, version) => _createSchema(db),
        onUpgrade: _upgrade,
      ),
    );
  }

  Future<void> _createSchema(DatabaseExecutor db) async {
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

  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 1) {
      await _createSchema(db);
      return;
    }
    if (newVersion > schemaVersion) {
      throw ArgumentError('unsupported feed schema version $newVersion');
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
