import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:parfait/core/history/history_database.dart';
import 'package:parfait/core/localnovel/local_novel_database.dart';
import 'package:parfait/core/paging/feed_database.dart';
import 'package:parfait/core/watchlater/watch_later_database.dart';

typedef _Owner = ({
  Future<Database> Function() database,
  Future<void> Function() close,
});

Future<List<String>> _tables(Database db) async => [
  for (final row in await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  ))
    row['name']! as String,
];

void main() {
  setUpAll(sqfliteFfiInit);
  final ffi = databaseFactoryFfi;

  // The feeds cache is rebuilt; a database holding the user's data refuses
  // to open, so the newer build finds its schema intact when it returns.
  final cases = <(String, int, bool, _Owner Function(String))>[
    (
      FeedDatabase.databaseName,
      FeedDatabase.schemaVersion,
      true,
      (file) {
        final d = FeedDatabase(factory: ffi, databasePath: file);
        return (database: () => d.database, close: d.close);
      },
    ),
    (
      HistoryDatabase.databaseName,
      HistoryDatabase.schemaVersion,
      false,
      (f) {
        final d = HistoryDatabase(factory: ffi, databasePath: f);
        return (database: () => d.database, close: d.close);
      },
    ),
    (
      WatchLaterDatabase.databaseName,
      WatchLaterDatabase.schemaVersion,
      false,
      (f) {
        final d = WatchLaterDatabase(factory: ffi, databasePath: f);
        return (database: () => d.database, close: d.close);
      },
    ),
    (
      LocalNovelDatabase.databaseName,
      LocalNovelDatabase.schemaVersion,
      false,
      (f) {
        final d = LocalNovelDatabase(factory: ffi, databasePath: f);
        return (database: () => d.database, close: d.close);
      },
    ),
  ];

  group('a database a newer build left behind', () {
    for (final (name, version, rebuilt, open) in cases) {
      test(name, () async {
        final directory = await Directory.systemTemp.createTemp('parfait-db-');
        addTearDown(() => directory.delete(recursive: true));
        final file = path.join(directory.path, name);
        final current = open(file);
        await current.database();
        await current.close();
        // What a newer build leaves: one version up, with a table of its own.
        final newer = await ffi.openDatabase(
          file,
          options: OpenDatabaseOptions(
            version: version + 1,
            onUpgrade: (db, _, _) => db.execute('CREATE TABLE newer (id INT)'),
          ),
        );
        await newer.close();

        final older = open(file);
        if (rebuilt) {
          final db = await older.database();
          expect(await db.getVersion(), version);
          expect(await _tables(db), isNot(contains('newer')));
          return older.close();
        }
        await expectLater(older.database(), throwsStateError);
        await older.close();
        final after = await ffi.openDatabase(file);
        expect(await after.getVersion(), version + 1);
        expect(await _tables(after), contains('newer'));
        await after.close();
      });
    }
  });
}
