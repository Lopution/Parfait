/// Shared SQLite factory selection and connection lifecycle owner for local
/// app databases (`history.db`, `feeds.db`, `actions.db`, `watchlater.db`,
/// `local_novels.db`).
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Selects the SQLite [DatabaseFactory] without reading [Platform] directly
/// for mobile detection.
///
/// Production uses `Platform.isAndroid || Platform.isIOS`. Tests pass the
/// flag directly because `flutter test` always reports a desktop [Platform].
DatabaseFactory sqliteDatabaseFactory({required bool useMobileSqflite}) {
  if (useMobileSqflite) return sqflite.databaseFactory;
  sqfliteFfiInit();
  // The isolate-backed factory's port replies never reach the fake-async
  // zone of `testWidgets`, which would suspend database reads forever. The
  // no-isolate variant answers through microtasks that `tester.pump` flushes.
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return databaseFactoryFfiNoIsolate;
  }
  return databaseFactoryFfi;
}

/// Owns one lazy SQLite connection, serializing concurrent opens and closes.
///
/// The connection opens on first [database] access and stays open until
/// [close]. Tests can inject an FFI [DatabaseFactory] and an explicit
/// [databasePath] without changing the production lifecycle.
class SqliteDatabase {
  SqliteDatabase({
    required this.databaseName,
    required this.schemaVersion,
    required sqflite.OnDatabaseCreateFn onCreate,
    required sqflite.OnDatabaseVersionChangeFn onUpgrade,
    required sqflite.OnDatabaseVersionChangeFn onDowngrade,
    sqflite.OnDatabaseConfigureFn? onConfigure,
    String? closedMessage,
    DatabaseFactory? factory,
    String? databasePath,
    @visibleForTesting bool? useInMemoryByDefault,
  }) : _onCreate = onCreate,
       _onUpgrade = onUpgrade,
       _onDowngrade = onDowngrade,
       _onConfigure = onConfigure,
       _closedMessage = closedMessage ?? '$databaseName is closed',
       _factory = factory ?? _platformDatabaseFactory(),
       _databasePath = databasePath,
       _useInMemoryByDefault =
           useInMemoryByDefault ??
           (Platform.environment['FLUTTER_TEST'] == 'true');

  final String databaseName;
  final int schemaVersion;
  final sqflite.OnDatabaseCreateFn _onCreate;
  final sqflite.OnDatabaseVersionChangeFn _onUpgrade;
  final sqflite.OnDatabaseVersionChangeFn _onDowngrade;
  final sqflite.OnDatabaseConfigureFn? _onConfigure;
  final String _closedMessage;
  final DatabaseFactory _factory;
  final String? _databasePath;
  final bool _useInMemoryByDefault;

  Future<Database>? _databaseFuture;
  Future<void>? _closeFuture;

  bool get _closed => _closeFuture != null;

  static DatabaseFactory _platformDatabaseFactory() {
    return sqliteDatabaseFactory(
      useMobileSqflite: Platform.isAndroid || Platform.isIOS,
    );
  }

  /// Returns an `onDowngrade` handler that refuses to open a database left by
  /// a newer app build so its schema stays intact (`SQLITE-02`).
  static sqflite.OnDatabaseVersionChangeFn refuseDowngrade(
    String databaseName,
  ) {
    return (db, from, to) async {
      throw StateError(
        '$databaseName is schema $from; this build reads up to $to',
      );
    };
  }

  /// Lazily opens and caches the single connection, serializing first access.
  Future<Database> get database {
    if (_closed) {
      return Future<Database>.error(StateError(_closedMessage));
    }
    return _databaseFuture ??= _open();
  }

  Future<Database> _open() async {
    final databasePath = _databasePath ?? await _defaultPath();
    if (_closed) {
      throw StateError(_closedMessage);
    }
    final isInMemory = databasePath == sqflite.inMemoryDatabasePath;
    return _factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        // The factory hands every opener of a path the same database,
        // `:memory:` included; each in-memory database must be its own.
        singleInstance: !isInMemory,
        onConfigure: (db) async {
          // Android sqflite rejects execute() on PRAGMAs that return a row.
          await db.rawQuery('PRAGMA busy_timeout = 5000');
          if (!isInMemory) {
            await db.rawQuery('PRAGMA journal_mode = WAL');
          }
          if (_onConfigure case final configure?) {
            await configure(db);
          }
        },
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onDowngrade: _onDowngrade,
      ),
    );
  }

  /// Under `flutter test`, an omitted path resolves in memory so widget tests
  /// leave no files or rows behind. Production resolves `<dir>/<name>`.
  Future<String> _defaultPath() async {
    if (_useInMemoryByDefault) {
      return sqflite.inMemoryDatabasePath;
    }
    return path.join(await _factory.getDatabasesPath(), databaseName);
  }

  /// Closes the connection idempotently, awaiting any in-flight open or close.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    final future = _databaseFuture;
    _databaseFuture = null;
    if (future == null) return;
    final Database db;
    try {
      db = await future;
    } on Object {
      // The open failed (e.g. a refused downgrade) or aborted on close.
      return;
    }
    if (db.isOpen) await db.close();
  }
}
