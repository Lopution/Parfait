import 'dart:ui';

import 'package:flutter/material.dart';

/// Image source exposed by settings. Network compatibility belongs to the
/// exact-host policy and cannot be selected by rewriting a CDN URL.
enum ImageSourceMode {
  normal('i.pximg.net');

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
    this.enableDoh = true,
    this.dohEndpointOverride,
    this.echFrontHost = defaultEchFrontHost,
    this.insecureNoSniEnabled = false,
    this.nativeWebViewIntercept = false,
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

  /// Built-in DoH endpoints. Used when [dohEndpointOverride] is null; an
  /// override replaces the whole list.
  ///
  /// Cloudflare DoH over anycast IPs (PixEz-proven bootstrap): anycast
  /// serves these endpoints on any Cloudflare IP, so the first query needs
  /// no system DNS round trip and no resolver recursion. Mainland DoH
  /// (AliDNSPod) poisons `*.pixiv.net` answers, so they are not defaults;
  /// users can add them through the override.
  static const List<String> defaultDohEndpoints = [
    'https://1dot1dot1dot1.cloudflare-dns.com/dns-query',
    'https://dns.google/dns-query',
  ];

  /// ECH front host (serves the ECH config for the pixiv Cloudflare
  /// domains). Configurable in settings; Cloudflare default.
  static const String defaultEchFrontHost = 'cloudflare-ech.com';
  static const SecretSettingRef translationCredentialRef = SecretSettingRef(
    'replica.settings.translate.v1',
  );

  final int schemaVersion;
  final bool guideCompleted;
  final String languageTag;
  final int themeCode;
  final String imageSource;

  /// Whether the strict tier uses DoH; when disabled the system resolver
  /// remains the only strict source (直连 + 系统 DNS).
  final bool enableDoh;

  /// Optional comma-separated DoH endpoint override. Null = built-in list.
  final String? dohEndpointOverride;

  /// ECH front host (HTTPS RR type 65 query target).
  final String echFrontHost;

  /// Whether the user explicitly enabled the `insecureNoSni` fallback tier
  /// (R6). Default false; never auto-enabled by probe failures.
  final bool insecureNoSniEnabled;

  /// R7: login WebView uses the native PlatformView (request interception
  /// through the policy ladder) instead of webview_flutter on Android.
  /// Default false — webview_flutter is the tested, stable path.
  final bool nativeWebViewIntercept;
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
      enableDoh: _bool(json['enableDoh'], base.enableDoh),
      dohEndpointOverride: _nullableString(
        json,
        'dohEndpointOverride',
        base.dohEndpointOverride,
      ),
      echFrontHost:
          json['echFrontHost'] is String &&
              (json['echFrontHost'] as String).isNotEmpty
          ? json['echFrontHost'] as String
          : base.echFrontHost,
      insecureNoSniEnabled: _bool(
        json['insecureNoSniEnabled'],
        base.insecureNoSniEnabled,
      ),
      nativeWebViewIntercept: _bool(
        json['nativeWebViewIntercept'],
        base.nativeWebViewIntercept,
      ),
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
      'enableDoh': enableDoh,
      'dohEndpointOverride': dohEndpointOverride,
      'echFrontHost': echFrontHost,
      'insecureNoSniEnabled': insecureNoSniEnabled,
      'nativeWebViewIntercept': nativeWebViewIntercept,
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

  /// Retained as a source-compatible no-rewrite helper. Image routing is now
  /// owned by the exact-host network policy, so settings never alter a URL.
  String rewriteImageUrl(String url) => url;

  static const _unset = Object();

  AppSettings copyWith({
    bool? guideCompleted,
    String? languageTag,
    int? themeCode,
    String? imageSource,
    bool? enableDoh,
    Object? dohEndpointOverride = _unset,
    String? echFrontHost,
    bool? insecureNoSniEnabled,
    bool? nativeWebViewIntercept,
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
      enableDoh: enableDoh ?? this.enableDoh,
      dohEndpointOverride: identical(dohEndpointOverride, _unset)
          ? this.dohEndpointOverride
          : dohEndpointOverride as String?,
      echFrontHost: echFrontHost ?? this.echFrontHost,
      insecureNoSniEnabled:
          insecureNoSniEnabled ?? this.insecureNoSniEnabled,
      nativeWebViewIntercept:
          nativeWebViewIntercept ?? this.nativeWebViewIntercept,
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
