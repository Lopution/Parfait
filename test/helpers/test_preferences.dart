import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

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

/// In-memory preferences whose `setString` fails, as on a full disk: every
/// time, or the first [failures] times.
final class StringWriteFailingPreferences
    extends InMemorySharedPreferencesAsync {
  StringWriteFailingPreferences({this.failures}) : super.empty();

  int? failures;

  @override
  Future<bool> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) {
    final left = failures;
    if (left != null && left == 0) return super.setString(key, value, options);
    if (left != null) failures = left - 1;
    return Future.error(StateError('disk full'));
  }
}

/// In-memory preferences whose calls wait on a gate, as a slow disk holds
/// them: a read waits for [readGate] and a write for [writeGate], and a
/// gate that fails, fails the call (a full disk). Null lets calls through.
/// Only calls on [keys] are gated, or every call when [keys] is null.
final class GatedPreferences extends InMemorySharedPreferencesAsync {
  GatedPreferences({this.keys}) : super.empty();

  final Set<String>? keys;
  Future<void>? readGate;
  Future<void>? writeGate;

  /// Reads and writes that touched [keys], gated or let through.
  int reads = 0;
  int writes = 0;

  bool _gates(Set<String>? touched) =>
      keys == null || touched == null || touched.any(keys!.contains);

  Future<T> _read<T>(Set<String>? touched, Future<T> Function() read) async {
    if (_gates(touched)) {
      reads++;
      await readGate;
    }
    return read();
  }

  Future<bool> _write(
    Set<String>? touched,
    Future<bool> Function() write,
  ) async {
    if (_gates(touched)) {
      writes++;
      await writeGate;
    }
    return write();
  }

  @override
  Future<String?> getString(String key, SharedPreferencesOptions options) =>
      _read({key}, () => super.getString(key, options));

  @override
  Future<bool?> getBool(String key, SharedPreferencesOptions options) =>
      _read({key}, () => super.getBool(key, options));

  @override
  Future<double?> getDouble(String key, SharedPreferencesOptions options) =>
      _read({key}, () => super.getDouble(key, options));

  @override
  Future<int?> getInt(String key, SharedPreferencesOptions options) =>
      _read({key}, () => super.getInt(key, options));

  @override
  Future<List<String>?> getStringList(
    String key,
    SharedPreferencesOptions options,
  ) => _read({key}, () => super.getStringList(key, options));

  @override
  Future<Map<String, Object>> getPreferences(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) => _read(
    parameters.filter.allowList,
    () => super.getPreferences(parameters, options),
  );

  @override
  Future<Set<String>> getKeys(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) => _read(
    parameters.filter.allowList,
    () => super.getKeys(parameters, options),
  );

  @override
  Future<bool> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) => _write({key}, () => super.setString(key, value, options));

  @override
  Future<bool> setBool(
    String key,
    bool value,
    SharedPreferencesOptions options,
  ) => _write({key}, () => super.setBool(key, value, options));

  @override
  Future<bool> setDouble(
    String key,
    double value,
    SharedPreferencesOptions options,
  ) => _write({key}, () => super.setDouble(key, value, options));

  @override
  Future<bool> setInt(
    String key,
    int value,
    SharedPreferencesOptions options,
  ) => _write({key}, () => super.setInt(key, value, options));

  @override
  Future<bool> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) => _write({key}, () => super.setStringList(key, value, options));

  @override
  Future<bool> clear(
    ClearPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) => _write(
    parameters.filter.allowList,
    () => super.clear(parameters, options),
  );
}
