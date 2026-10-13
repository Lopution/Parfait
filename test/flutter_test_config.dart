import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Gives each test file its own default databases directory (TEST-07).
///
/// The app opens its databases at `<databases path>/<name>.db`. Under
/// `flutter test` that is one `.dart_tool` directory shared by every file
/// running in parallel, so two files opening the same default database
/// failed with `database is locked`.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final directory = Directory.systemTemp.createTempSync('parfait-db-');
  await databaseFactoryFfi.setDatabasesPath(directory.path);
  await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
  await testMain();
  tearDownAll(() => directory.deleteSync(recursive: true));
}
