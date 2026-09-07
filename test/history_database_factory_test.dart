import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/history/history_database.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('mobile factory is sqflite.databaseFactory, not FFI', () {
    // `flutter test` runs on Linux: the Android/iOS plugin never registers
    // the default factory, so `sqflite.databaseFactory` throws until set.
    // Install the same plugin instance Android would, then restore.
    final previous = sqflite.databaseFactoryOrNull;
    addTearDown(() => sqflite.databaseFactory = previous);
    sqflite.databaseFactory = sqflite.databaseFactorySqflitePlugin;

    final factory = historyDatabaseFactory(useMobileSqflite: true);
    expect(identical(factory, sqflite.databaseFactory), isTrue);
    expect(identical(factory, sqflite.databaseFactorySqflitePlugin), isTrue);
    expect(identical(factory, databaseFactoryFfi), isFalse);
  });
}
