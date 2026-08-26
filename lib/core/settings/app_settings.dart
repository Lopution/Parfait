import 'dart:ui';

import 'package:flutter/material.dart';

class AppSettings {
  const AppSettings({
    required this.guideCompleted,
    required this.languageTag,
    required this.themeCode,
  });

  static const int systemTheme = -1;
  static const int darkTheme = 0;
  static const int lightTheme = 1;

  final bool guideCompleted;
  final String languageTag;
  final int themeCode;

  factory AppSettings.defaults() {
    return AppSettings(
      guideCompleted: false,
      languageTag: _supportedLanguageTag(PlatformDispatcher.instance.locale),
      themeCode: systemTheme,
    );
  }

  static String canonicalLanguageTag(String value) {
    final normalized = value.replaceAll('_', '-').toLowerCase();
    if (normalized.startsWith('en')) return 'en-US';
    if (normalized.startsWith('ja')) return 'ja-JP';
    if (normalized.startsWith('ru')) return 'ru-RU';
    return 'zh-CN';
  }

  static String _supportedLanguageTag(Locale locale) {
    return canonicalLanguageTag(locale.toLanguageTag());
  }

  Locale get locale {
    final parts = languageTag.split('-');
    return Locale(parts.first, parts.length > 1 ? parts[1] : null);
  }

  ThemeMode get themeMode => switch (themeCode) {
        darkTheme => ThemeMode.dark,
        lightTheme => ThemeMode.light,
        _ => ThemeMode.system,
      };

  AppSettings copyWith({
    bool? guideCompleted,
    String? languageTag,
    int? themeCode,
  }) {
    return AppSettings(
      guideCompleted: guideCompleted ?? this.guideCompleted,
      languageTag: languageTag == null
          ? this.languageTag
          : canonicalLanguageTag(languageTag),
      themeCode: themeCode ?? this.themeCode,
    );
  }
}
