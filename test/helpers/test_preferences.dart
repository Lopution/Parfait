import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// In-memory [SharedPreferencesAsync] for tests (C5b helper).
///
/// Pass into [sharedPreferencesProvider.overrideWithValue] or straight into a
/// store constructor.
InMemorySharedPreferencesAsync memoryPreferences([
  Map<String, Object> data = const {},
]) => InMemorySharedPreferencesAsync.withData(data);

/// Registers the in-memory platform so provider-graph tests never touch the
/// missing SharedPreferences plugin. Call once at the top of main().
void installMemoryPreferences([Map<String, Object> data = const {}]) {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.withData(data);
}

/// Installs [platform] until the running test ends: a failing one must not
/// reach the tests after it.
void installPreferencesForTest(SharedPreferencesAsyncPlatform platform) {
  final previous = SharedPreferencesAsyncPlatform.instance;
  SharedPreferencesAsyncPlatform.instance = platform;
  addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
}

/// In-memory preferences whose `setInt` fails, as on a full disk; the
/// reads a page loads with still answer.
final class IntWriteFailingPreferences extends InMemorySharedPreferencesAsync {
  IntWriteFailingPreferences() : super.empty();

  /// Each value a write was asked for.
  final intWrites = <int>[];

  @override
  Future<bool> setInt(String key, int value, SharedPreferencesOptions options) {
    intWrites.add(value);
    return Future.error(StateError('disk full'));
  }
}

/// In-memory preferences whose `setString` fails, as on a full disk.
final class StringWriteFailingPreferences
    extends InMemorySharedPreferencesAsync {
  StringWriteFailingPreferences() : super.empty();

  @override
  Future<bool> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) => Future.error(StateError('disk full'));
}
