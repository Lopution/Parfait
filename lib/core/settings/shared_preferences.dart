import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preference_keys.dart';

/// Single owner of the app-wide [SharedPreferencesAsync] instance (C5b).
///
/// Production code never constructs a preferences instance directly; stores
/// receive one through their constructor from a provider that watches this.
/// Tests override this provider or inject an in-memory implementation.
final sharedPreferencesProvider = Provider<SharedPreferencesAsync>((ref) {
  return SharedPreferencesAsync();
});

/// Whether the developer entries (frame probe…) are unlocked. Off by default
/// in every build channel; the about-page version tap gesture flips it, and
/// non-release builds count as always-unlocked at the call site.
final developerOptionsProvider =
    NotifierProvider<_DeveloperOptionsNotifier, bool>(
      _DeveloperOptionsNotifier.new,
    );

class _DeveloperOptionsNotifier extends Notifier<bool> {
  @override
  bool build() {
    ref
        .watch(sharedPreferencesProvider)
        .getBool(PreferenceKeys.developerOptions)
        .then((value) {
          if (value == true) state = true;
        });
    return false;
  }

  Future<void> unlock() async {
    state = true;
    await ref
        .read(sharedPreferencesProvider)
        .setBool(PreferenceKeys.developerOptions, true);
  }
}
