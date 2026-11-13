import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:parfait/core/sqlite/sqlite_database.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<void> noopCreate(sqflite.Database db, int v) async {}
  Future<void> noopUpgrade(sqflite.Database db, int from, int to) async {}

  SqliteDatabase subject(DatabaseFactory factory, {bool? inMemory}) =>
      SqliteDatabase(
        databaseName: 'sample.db',
        schemaVersion: 1,
        onCreate: noopCreate,
        onUpgrade: noopUpgrade,
        onDowngrade: SqliteDatabase.refuseDowngrade('sample.db'),
        factory: factory,
        useInMemoryByDefault: inMemory,
      );

  test('sqliteDatabaseFactory selects mobile sqflite or FLUTTER_TEST FFI', () {
    final previous = sqflite.databaseFactoryOrNull;
    addTearDown(() => sqflite.databaseFactory = previous);
    sqflite.databaseFactory = sqflite.databaseFactorySqflitePlugin;

    final mobile = sqliteDatabaseFactory(useMobileSqflite: true);
    final ffi = sqliteDatabaseFactory(useMobileSqflite: false);
    expect(identical(mobile, sqflite.databaseFactory), isTrue);
    expect(identical(mobile, databaseFactoryFfi), isFalse);
    expect(identical(ffi, databaseFactoryFfiNoIsolate), isTrue);
  });

  test('concurrent first database access opens once', () async {
    final gate = Completer<void>();
    final factory = _GatedDatabaseFactory(databaseFactoryFfi, openGate: gate);
    final db = subject(factory);
    addTearDown(db.close);

    final futures = [db.database, db.database];
    gate.complete();
    final opened = await Future.wait(futures);
    expect(identical(opened[0], opened[1]), isTrue);
    expect(factory.openCalls, hasLength(1));
  });

  test(
    'concurrent close waits for in-flight openDatabase to finish closing',
    () async {
      final gate = Completer<void>();
      final factory = _GatedDatabaseFactory(databaseFactoryFfi, openGate: gate);
      final db = subject(factory);

      final openFuture = db.database;
      await Future<void>.delayed(Duration.zero);

      var done1 = false;
      var done2 = false;
      final c1 = db.close().then((_) => done1 = true);
      final c2 = db.close().then((_) => done2 = true);
      await Future<void>.delayed(Duration.zero);
      expect([done1, done2], [false, false]);

      gate.complete();
      final conn = await openFuture;
      await Future.wait([c1, c2]);
      expect([done1, done2, conn.isOpen], [true, true, false]);
    },
  );

  test(
    'close during async default path skips openDatabase and rejects open',
    () async {
      final pathGate = Completer<void>();
      final factory = _GatedDatabaseFactory(
        databaseFactoryFfi,
        pathGate: pathGate,
      );
      final db = subject(factory, inMemory: false);

      final openError = expectLater(db.database, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final closeFuture = db.close();
      pathGate.complete();
      await Future.wait([closeFuture, openError]);
      expect(factory.openCalls, isEmpty);
    },
  );

  test(
    'routes default path to memory in test and <databasesPath>/<name> when enabled',
    () async {
      final dir = await Directory.systemTemp.createTemp('parfait-sqlite-');
      addTearDown(() => dir.delete(recursive: true));
      final expectedDisk = path.join(dir.path, 'sample.db');
      for (final (inMem, expected, single) in [
        (true, sqflite.inMemoryDatabasePath, false),
        (false, expectedDisk, true),
      ]) {
        final f = _GatedDatabaseFactory(databaseFactoryFfi, dir: dir.path);
        final db = subject(f, inMemory: inMem);
        await db.database;
        await db.close();
        expect(f.openCalls.single.$1, expected);
        expect(f.openCalls.single.$2?.singleInstance, single);
      }
    },
  );

  test(
    'close is safe when never opened or failed and blocks later opens',
    () async {
      final closed = subject(databaseFactoryFfi);
      await closed.close();
      await expectLater(closed.database, throwsStateError);

      final f = _GatedDatabaseFactory(
        databaseFactoryFfi,
        openError: StateError('fail'),
      );
      final failed = subject(f);
      await expectLater(failed.database, throwsStateError);
      await failed.close();
    },
  );
}

class _GatedDatabaseFactory implements DatabaseFactory {
  _GatedDatabaseFactory(
    this._inner, {
    this.openGate,
    this.pathGate,
    this.openError,
    this.dir,
  });

  final DatabaseFactory _inner;
  final Completer<void>? openGate;
  final Completer<void>? pathGate;
  final Object? openError;
  final String? dir;
  final List<(String, OpenDatabaseOptions?)> openCalls = [];

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    openCalls.add((path, options));
    if (openGate case final gate?) await gate.future;
    if (openError case final error?) throw error;
    return _inner.openDatabase(path, options: options);
  }

  @override
  Future<String> getDatabasesPath() async {
    if (pathGate case final gate?) await gate.future;
    return dir ?? _inner.getDatabasesPath();
  }

  @override
  Future<void> setDatabasesPath(String p) => _inner.setDatabasesPath(p);

  @override
  Future<void> deleteDatabase(String p) => _inner.deleteDatabase(p);

  @override
  Future<bool> databaseExists(String p) => _inner.databaseExists(p);

  @override
  Future<Uint8List> readDatabaseBytes(String p) => _inner.readDatabaseBytes(p);

  @override
  Future<void> writeDatabaseBytes(String p, Uint8List b) =>
      _inner.writeDatabaseBytes(p, b);
}
