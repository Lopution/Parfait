import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Single owner of the app-wide [SharedPreferencesAsync] instance (C5b).
///
/// Production code never constructs a preferences instance directly; stores
/// receive one through their constructor from a provider that watches this.
/// Tests override this provider or inject an in-memory implementation.
final sharedPreferencesProvider = Provider<SharedPreferencesAsync>((ref) {
  return SharedPreferencesAsync();
});
