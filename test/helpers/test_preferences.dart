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
