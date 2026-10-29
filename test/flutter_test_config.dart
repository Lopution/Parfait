import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/leak_tracking.dart';
import 'helpers/test_preferences.dart';

/// Gives each test file its own default databases directory (TEST-07) and
/// each case empty in-memory preferences (TEST-09).
///
/// The app opens its databases at `<databases path>/<name>.db`. Under
/// `flutter test` that is one `.dart_tool` directory shared by every file
/// running in parallel, so two files opening the same default database
/// failed with `database is locked`. The preferences plugin is missing
/// under `flutter test`; a case that needs stored values installs its own.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  enableLeakTracking();
  final directory = Directory.systemTemp.createTempSync('parfait-db-');
  await databaseFactoryFfi.setDatabasesPath(directory.path);
  await databaseFactoryFfiNoIsolate.setDatabasesPath(directory.path);
  setUp(installMemoryPreferences);
  await testMain();
  tearDownAll(() => directory.deleteSync(recursive: true));
}
