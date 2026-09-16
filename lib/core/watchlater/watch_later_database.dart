/// SQLite connection and schema owner for the local `watchlater.db`
/// database. Mirrors `history_database.dart`: [WatchLaterDatabase] owns the
/// lazy connection and factory choice; CRUD belongs to
/// [WatchLaterRepository]. See `database-guidelines.md`.
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Chooses the watch-later SQLite factory without reading [Platform].
///
/// Production calls this with `useMobileSqflite: Platform.isAndroid ||
/// Platform.isIOS`. Tests pass the flag directly because `flutter test`
/// always reports a desktop [Platform].
@visibleForTesting
DatabaseFactory watchLaterDatabaseFactory({required bool useMobileSqflite}) {
  if (useMobileSqflite) return sqflite.databaseFactory;
  sqfliteFfiInit();
  return databaseFactoryFfi;
}

/// Owns the one SQLite connection used by the watch-later feature.
///
/// The connection is opened lazily once and remains open until the Riverpod
/// container is disposed. Tests can inject an FFI [DatabaseFactory] and a
/// temporary path without changing the production lifecycle.
class WatchLaterDatabase {
  WatchLaterDatabase({DatabaseFactory? factory, String? databasePath})
    : _factory = factory ?? _platformDatabaseFactory(),
      _databasePath = databasePath;

  static const databaseName = 'watchlater.db';
  static const table = 'watch_later_entries';
  static const schemaVersion = 1;

  final DatabaseFactory _factory;
  final String? _databasePath;
  Future<Database>? _databaseFuture;
  bool _closed = false;

  static DatabaseFactory _platformDatabaseFactory() {
    return watchLaterDatabaseFactory(
      useMobileSqflite: Platform.isAndroid || Platform.isIOS,
    );
  }

  /// The single connection future also serializes concurrent first access.
  Future<Database> get database {
    if (_closed) {
      return Future<Database>.error(
        StateError('watch-later database is closed'),
      );
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

  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 1) {
      await _createSchema(db);
      return;
    }
    if (newVersion > schemaVersion) {
      throw ArgumentError('unsupported watch-later schema version $newVersion');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final future = _databaseFuture;
    _databaseFuture = null;
    if (future != null) {
      final database = await future;
      await database.close();
    }
  }
}
