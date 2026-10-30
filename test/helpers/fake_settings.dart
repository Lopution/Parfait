import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/preference_keys.dart';
import 'package:parfait/core/settings/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's settings repository over this case's in-memory preferences:
/// what a test seeds or reads back.
SettingsRepository storedSettings() =>
    PreferencesSettingsRepository(preferences: SharedPreferencesAsync());

/// Stores [settings] through [storedSettings].
Future<void> seedSettings(AppSettings settings) =>
    storedSettings().save(settings);

/// Stores the defaults with the local filter switches given.
Future<void> seedFilterSettings({
  bool blockR18 = false,
  bool hideMuted = false,
}) => seedSettings(
  AppSettings.defaults().copyWith(
    enableLocalBlockR18: blockR18,
    hideMuted: hideMuted,
  ),
);

/// The preference key settings are stored under, for gating its calls.
const settingsKeys = {PreferenceKeys.settings};
