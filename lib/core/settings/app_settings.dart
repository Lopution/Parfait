import 'dart:ui';

import 'package:flutter/material.dart';

/// Image hosts understood by the settings contract.
///
/// The normal route is the only default. The IP route is retained solely as
/// an explicit emergency compatibility choice; it must never be selected by
/// migration or by an invalid value.
enum ImageSourceMode {
  normal('i.pximg.net'),
  legacyIp('210.140.92.148'),
  pixivRe('i.pixiv.re');

  const ImageSourceMode(this.host);

  final String host;

  static ImageSourceMode? fromHost(String? host) {
    for (final mode in values) {
      if (mode.host == host) return mode;
    }
    return null;
  }
}

/// Non-secret translation provider selection. Credentials, when a later
/// translation feature needs them, are referenced from secure storage only.
enum TranslationProvider {
  google(0),
  disabled(1);

  const TranslationProvider(this.code);

  final int code;

  static TranslationProvider? fromCode(Object? value) {
    if (value is! int) return null;
    for (final provider in values) {
      if (provider.code == value) return provider;
    }
    return null;
  }
}

/// A non-secret pointer to a credential stored by [CredentialStore].
///
/// This object is intentionally not serializable as part of [AppSettings].
/// It identifies a secure-storage record without carrying the record's
/// token, cookie, or API key.
class SecretSettingRef {
  const SecretSettingRef(this.credentialKey);

  final String credentialKey;

  @override
  String toString() => 'SecretSettingRef(credentialKey: $credentialKey)';
}

class AppSettings {
  const AppSettings({
    required this.guideCompleted,
    required this.languageTag,
    required this.themeCode,
    this.imageSource = normalImageSource,
    this.previewQuality = true,
    this.scaleQuality = true,
    this.enableHistory = true,
    this.enablePixivHistory = true,
    this.enableLocalBlockR18 = false,
    this.enableLocalBlockAI = false,
    this.translateIndex = 0,
    this.maxDownloadCount = defaultMaxDownloadCount,
    this.savePath,
    this.saveFolder,
    this.namingRule,
    this.schemaVersion = currentSchemaVersion,
  });

  static const int currentSchemaVersion = 2;
  static const int systemTheme = -1;
  static const int darkTheme = 0;
  static const int lightTheme = 1;
  static const int defaultMaxDownloadCount = 3;
  static const String normalImageSource = 'i.pximg.net';
  static const String legacyImageSource = '210.140.92.148';
  static const String mirrorImageSource = 'i.pixiv.re';
  static const SecretSettingRef translationCredentialRef = SecretSettingRef(
    'replica.settings.translate.v1',
  );

  final int schemaVersion;
  final bool guideCompleted;
  final String languageTag;
  final int themeCode;
  final String imageSource;
  final bool previewQuality;
  final bool scaleQuality;
  final bool enableHistory;
  final bool enablePixivHistory;
  final bool enableLocalBlockR18;
  final bool enableLocalBlockAI;
  final int translateIndex;
  final int maxDownloadCount;
  final String? savePath;
  final String? saveFolder;
  final String? namingRule;

  factory AppSettings.defaults() {
    return AppSettings(
      guideCompleted: false,
      languageTag: _supportedLanguageTag(PlatformDispatcher.instance.locale),
      themeCode: systemTheme,
    );
  }

  /// Reads both the current schema names and beta56's legacy camelCase names.
  /// Every field is validated independently so one damaged value cannot
  /// discard otherwise valid settings.
  factory AppSettings.fromJson(
    Map<String, dynamic> json, {
    AppSettings? fallback,
  }) {
    final base = fallback ?? AppSettings.defaults();
    final source = json['imageSource'] ?? json['imageSourceMode'];
    final provider = TranslationProvider.fromCode(
      json['translateIndex'] ?? json['translationProvider'],
    );
    final maxDownloads = json['maxDownloadCount'];
    return AppSettings(
      schemaVersion: currentSchemaVersion,
      guideCompleted: _bool(
        json['guideCompleted'] ?? json['guideInit'],
        base.guideCompleted,
      ),
      languageTag: _language(
        json['languageTag'] ?? json['language'],
        base.languageTag,
      ),
      themeCode: _theme(json['themeCode'] ?? json['theme'], base.themeCode),
      imageSource: source is String && ImageSourceMode.fromHost(source) != null
          ? source
          : base.imageSource,
      previewQuality: _bool(json['previewQuality'], base.previewQuality),
      scaleQuality: _bool(json['scaleQuality'], base.scaleQuality),
      enableHistory: _bool(json['enableHistory'], base.enableHistory),
      enablePixivHistory: _bool(
        json['enablePixivHistory'],
        base.enablePixivHistory,
      ),
      enableLocalBlockR18: _bool(
        json['enableLocalBlockR18'],
        base.enableLocalBlockR18,
      ),
      enableLocalBlockAI: _bool(
        json['enableLocalBlockAI'],
        base.enableLocalBlockAI,
      ),
      translateIndex: provider?.code ?? base.translateIndex,
      maxDownloadCount: _maxDownloads(maxDownloads, base.maxDownloadCount),
      savePath: _nullableString(json, 'savePath', base.savePath),
      saveFolder: _nullableString(json, 'saveFolder', base.saveFolder),
      namingRule: _nullableString(json, 'namingRule', base.namingRule),
    );
  }

  /// Plain settings JSON contains no [SecretSettingRef] or secret value.
  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': currentSchemaVersion,
      'guideCompleted': guideCompleted,
      'languageTag': languageTag,
      'themeCode': themeCode,
      'imageSource': imageSource,
      'previewQuality': previewQuality,
      'scaleQuality': scaleQuality,
      'enableHistory': enableHistory,
      'enablePixivHistory': enablePixivHistory,
      'enableLocalBlockR18': enableLocalBlockR18,
      'enableLocalBlockAI': enableLocalBlockAI,
      'translateIndex': translateIndex,
      'maxDownloadCount': maxDownloadCount,
      'savePath': savePath,
      'saveFolder': saveFolder,
      'namingRule': namingRule,
    };
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

  ImageSourceMode get imageSourceMode =>
      ImageSourceMode.fromHost(imageSource) ?? ImageSourceMode.normal;

  bool get isLegacyImageSource => imageSourceMode == ImageSourceMode.legacyIp;

  TranslationProvider get translationProvider =>
      TranslationProvider.fromCode(translateIndex) ??
      TranslationProvider.google;

  // Descriptive aliases used by consumers; beta56-compatible field names
  // remain the canonical public storage contract above.
  bool get localHistoryEnabled => enableHistory;
  bool get pixivHistoryEnabled => enablePixivHistory;
  bool get blockR18 => enableLocalBlockR18;
  bool get blockAI => enableLocalBlockAI;
  int get maxDownloads => maxDownloadCount;

  /// Rewrites only the official CDN host. Normal mode returns the original
  /// HTTPS URL byte-for-byte; the legacy route is opt-in and visible in UI.
  String rewriteImageUrl(String url) {
    if (imageSourceMode == ImageSourceMode.normal) return url;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host != normalImageSource) {
      return url;
    }
    return uri.replace(host: imageSource).toString();
  }

  static const _unset = Object();

  AppSettings copyWith({
    bool? guideCompleted,
    String? languageTag,
    int? themeCode,
    String? imageSource,
    bool? previewQuality,
    bool? scaleQuality,
    bool? enableHistory,
    bool? enablePixivHistory,
    bool? enableLocalBlockR18,
    bool? enableLocalBlockAI,
    int? translateIndex,
    int? maxDownloadCount,
    Object? savePath = _unset,
    Object? saveFolder = _unset,
    Object? namingRule = _unset,
  }) {
    return AppSettings(
      schemaVersion: currentSchemaVersion,
      guideCompleted: guideCompleted ?? this.guideCompleted,
      languageTag: languageTag == null
          ? this.languageTag
          : canonicalLanguageTag(languageTag),
      themeCode: _theme(themeCode, this.themeCode),
      imageSource:
          imageSource != null && ImageSourceMode.fromHost(imageSource) != null
          ? imageSource
          : this.imageSource,
      previewQuality: previewQuality ?? this.previewQuality,
      scaleQuality: scaleQuality ?? this.scaleQuality,
      enableHistory: enableHistory ?? this.enableHistory,
      enablePixivHistory: enablePixivHistory ?? this.enablePixivHistory,
      enableLocalBlockR18: enableLocalBlockR18 ?? this.enableLocalBlockR18,
      enableLocalBlockAI: enableLocalBlockAI ?? this.enableLocalBlockAI,
      translateIndex:
          TranslationProvider.fromCode(translateIndex)?.code ??
          this.translateIndex,
      maxDownloadCount: _maxDownloads(maxDownloadCount, this.maxDownloadCount),
      savePath: identical(savePath, _unset)
          ? this.savePath
          : savePath as String?,
      saveFolder: identical(saveFolder, _unset)
          ? this.saveFolder
          : saveFolder as String?,
      namingRule: identical(namingRule, _unset)
          ? this.namingRule
          : namingRule as String?,
    );
  }

  static bool _bool(Object? value, bool fallback) =>
      value is bool ? value : fallback;

  static String _language(Object? value, String fallback) =>
      value is String ? canonicalLanguageTag(value) : fallback;

  static int _theme(Object? value, int fallback) {
    if (value is int && {systemTheme, darkTheme, lightTheme}.contains(value)) {
      return value;
    }
    return fallback;
  }

  static int _maxDownloads(Object? value, int fallback) {
    if (value is int && value >= 1 && value <= 10) return value;
    return fallback;
  }

  static String? _nullableString(
    Map<String, dynamic> json,
    String key,
    String? fallback,
  ) {
    if (!json.containsKey(key)) return fallback;
    final value = json[key];
    if (value == null) return null;
    return value is String && value.length <= 512 ? value : fallback;
  }
}
