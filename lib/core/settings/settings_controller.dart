import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';

class SettingsController extends AsyncNotifier<AppSettings> {
  static const _guideCompletedKey = 'replica.guide_completed';
  static const _languageKey = 'replica.language';
  static const _themeKey = 'replica.theme';

  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  late AppSettings _current;

  @override
  Future<AppSettings> build() async {
    final defaults = AppSettings.defaults();
    _current = AppSettings(
      guideCompleted: await _preferences.getBool(_guideCompletedKey) ??
          defaults.guideCompleted,
      languageTag: AppSettings.canonicalLanguageTag(
        await _preferences.getString(_languageKey) ?? defaults.languageTag,
      ),
      themeCode: await _preferences.getInt(_themeKey) ?? defaults.themeCode,
    );
    return _current;
  }

  Future<void> selectLanguage(String languageTag) async {
    _current = _current.copyWith(languageTag: languageTag);
    state = AsyncData(_current);
    await _preferences.setString(_languageKey, _current.languageTag);
  }

  Future<void> selectTheme(int themeCode) async {
    _current = _current.copyWith(themeCode: themeCode);
    state = AsyncData(_current);
    await _preferences.setInt(_themeKey, themeCode);
  }

  Future<void> completeGuide() async {
    _current = _current.copyWith(guideCompleted: true);
    state = AsyncData(_current);
    await _preferences.setBool(_guideCompletedKey, true);
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);
