/// Versioned non-secret settings values and their typed option mappings.
/// [AppSettings] owns the persisted aggregate shape; consumers expose their
/// own fine-grained providers. See `frontend/state-management.md`.
library;

import 'dart:ui';

import 'package:material_ui/material_ui.dart';

import '../download/download_destination.dart';
import '../download/naming_rule.dart';
import '../reverse_image/reverse_image_engine.dart';
import 'image_mirror.dart';

export 'image_mirror.dart' show ImageSourceMode, ImageMirror;

/// Non-secret translation provider selection. Credentials, when a later
/// translation feature needs them, are referenced from secure storage only.
enum TranslationProvider {
  google(0),
  disabled(1),
  baidu(2),
  translationLlm(3);

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

/// Preview (feed card) image quality (D4). Default [medium].
///
/// Feed APIs only provide `image_urls.medium/large` — there is no original
/// URL in list payloads, so original is deliberately not an option (an
/// "original" preview would silently show large).
enum PreviewQuality {
  medium(0),
  large(1);

  const PreviewQuality(this.code);

  final int code;

  static PreviewQuality fromCode(Object? value) {
    if (value is int) {
      // Legacy saved value (code 2 = original) migrates to large: the old
      // setting already displayed large in practice.
      if (value == 2) return PreviewQuality.large;
      for (final quality in values) {
        if (quality.code == value) return quality;
      }
    }
    return PreviewQuality.medium;
  }

  /// Legacy bool migration: `true` -> large, `false` -> medium.
  static PreviewQuality fromLegacyBool(Object? value) =>
      value == true ? PreviewQuality.large : PreviewQuality.medium;
}

/// Viewer image quality (D4). Default [original].
enum ViewQuality {
  medium(0),
  large(1),
  original(2);

  const ViewQuality(this.code);

  final int code;

  static ViewQuality fromCode(Object? value) {
    if (value is int) {
      for (final quality in values) {
        if (quality.code == value) return quality;
      }
    }
    return ViewQuality.original;
  }

  /// Legacy bool migration: `true` -> original, `false` -> large.
  static ViewQuality fromLegacyBool(Object? value) =>
      value == true ? ViewQuality.original : ViewQuality.large;
}

/// Detail-page main image quality (三档之详情档). Default [large]; the
/// medium option is available for code compatibility but served as large
/// because a 540px image is unreadable as the detail hero.
enum DetailQuality {
  medium(0),
  large(1),
  original(2);

  const DetailQuality(this.code);

  final int code;

  static DetailQuality fromCode(Object? value) {
    if (value is int) {
      for (final quality in values) {
        if (quality.code == value) return quality;
      }
    }
    return DetailQuality.large;
  }
}

/// How the normal network stack routes traffic (D3). Only the user choice is
/// persisted; route memory and probe results are never saved.
enum NetworkMode {
  automatic(0),
  directOnly(1);

  const NetworkMode(this.code);

  final int code;

  static NetworkMode? tryFromCode(Object? value) {
    if (value is int) {
      for (final mode in values) {
        if (mode.code == value) return mode;
      }
    }
    return null;
  }

  static NetworkMode fromCode(Object? value) {
    return tryFromCode(value) ?? NetworkMode.automatic;
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
    this.customImageSource,
    this.enableDoh = true,
    this.dohEndpointOverride,
    this.echFrontHost = defaultEchFrontHost,
    this.previewQuality = PreviewQuality.medium,
    this.viewQuality = ViewQuality.original,
    this.detailQuality = DetailQuality.large,
    this.networkMode = NetworkMode.automatic,
    this.enableHistory = true,
    this.enablePixivHistory = true,
    this.enableLocalBlockR18 = false,
    this.enableLocalBlockAI = false,
    this.hideMuted = false,
    this.reduceMotion = false,
    this.translateIndex = 1,
    this.maxDownloadCount = defaultMaxDownloadCount,
    this.downloadDestination = DownloadDestination.builtin,
    this.downloadCaption = false,
    this.namingRule = NamingRule.defaultRule,
    this.reverseImageEngine = ReverseImageEngine.sauceNao,
    this.schemaVersion = currentSchemaVersion,
  });

  static const int currentSchemaVersion = 3;
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

  /// Last used custom mirror prefix (`https://host[/path]`), remembered so
  /// switching preset → custom → preset does not lose the user's proxy.
  /// The active custom selection lives in [imageSource] itself.
  final String? customImageSource;

  /// Whether the strict tier uses DoH; when disabled the system resolver
  /// remains the only strict source (直连 + 系统 DNS).
  final bool enableDoh;

  /// Optional comma-separated DoH endpoint override. Null = built-in list.
  final String? dohEndpointOverride;

  /// ECH front host (HTTPS RR type 65 query target).
  final String echFrontHost;

  final PreviewQuality previewQuality;
  final ViewQuality viewQuality;
  final DetailQuality detailQuality;
  final NetworkMode networkMode;
  final bool enableHistory;
  final bool enablePixivHistory;
  final bool enableLocalBlockR18;
  final bool enableLocalBlockAI;

  /// Muted works presentation: false renders the blur+reveal card variant
  /// in feeds; true restores the old filter-them-out behaviour. Either way
  /// the mute set itself is the MuteStore (tag/user server-synced, works
  /// local); this flag only picks the presentation.
  final bool hideMuted;

  /// Collapses decorative motion (transitions, entrance stagger, press
  /// scale, sheet/dialog presentation) to instant state changes. Merged
  /// with the platform `disableAnimations` flag inside `MotionTokens`.
  final bool reduceMotion;
  final int translateIndex;
  final int maxDownloadCount;
  final DownloadDestination downloadDestination;

  /// Caption sidecar export (`<stem>.txt` next to the image) — off by
  /// default; opt-in in download settings.
  final bool downloadCaption;

  /// File naming (D6): preset or bounded custom template.
  final NamingRule namingRule;

  /// Last selected reverse-image engine; persisted so the page reopens on
  /// the engine the user chose. Unknown persisted values fall back to
  /// [ReverseImageEngine.sauceNao].
  final ReverseImageEngine reverseImageEngine;

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
    final legacyPreview = json['previewQuality'];
    final legacyScale = json['scaleQuality'];
    final legacyNaming = json['namingRule'];
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
      imageSource: source is String && ImageMirror.isValidSource(source)
          ? (ImageSourceMode.fromHost(source) != null
                ? source
                : ImageMirror.normalizeCustomSource(source)!)
          : base.imageSource,
      customImageSource:
          _nullableString(json, 'customImageSource', base.customImageSource) ??
          (source is String && ImageSourceMode.fromHost(source) == null
              ? ImageMirror.normalizeCustomSource(source)
              : null),
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
      previewQuality: json['previewQualityCode'] is int
          ? PreviewQuality.fromCode(json['previewQualityCode'])
          : legacyPreview is bool
          ? PreviewQuality.fromLegacyBool(legacyPreview)
          : base.previewQuality,
      viewQuality: json['viewQualityCode'] is int
          ? ViewQuality.fromCode(json['viewQualityCode'])
          : legacyScale is bool
          ? ViewQuality.fromLegacyBool(legacyScale)
          : base.viewQuality,
      detailQuality: json['detailQualityCode'] is int
          ? DetailQuality.fromCode(json['detailQualityCode'])
          : base.detailQuality,
      networkMode:
          NetworkMode.tryFromCode(json['networkModeCode']) ?? base.networkMode,
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
      hideMuted: _bool(json['hideMuted'], base.hideMuted),
      reduceMotion: _bool(json['reduceMotion'], base.reduceMotion),
      translateIndex: provider?.code ?? base.translateIndex,
      maxDownloadCount: _maxDownloads(maxDownloads, base.maxDownloadCount),
      downloadDestination: _readDestination(json, base.downloadDestination),
      downloadCaption: _bool(json['downloadCaption'], base.downloadCaption),
      namingRule: _readNamingRule(json, legacyNaming, base.namingRule),
      reverseImageEngine:
          ReverseImageEngine.tryFromName(json['reverseImageEngine']) ??
          base.reverseImageEngine,
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
      'customImageSource': customImageSource,
      'enableDoh': enableDoh,
      'dohEndpointOverride': dohEndpointOverride,
      'echFrontHost': echFrontHost,
      'previewQualityCode': previewQuality.code,
      'viewQualityCode': viewQuality.code,
      'detailQualityCode': detailQuality.code,
      'networkModeCode': networkMode.code,
      'enableHistory': enableHistory,
      'enablePixivHistory': enablePixivHistory,
      'enableLocalBlockR18': enableLocalBlockR18,
      'enableLocalBlockAI': enableLocalBlockAI,
      'hideMuted': hideMuted,
      'reduceMotion': reduceMotion,
      'translateIndex': translateIndex,
      'maxDownloadCount': maxDownloadCount,
      ...downloadDestination.toJson(),
      'downloadCaption': downloadCaption,
      'namingPreset': namingRule.preset.code,
      if (namingRule.preset == NamingPreset.custom)
        'namingTemplate': namingRule.template,
      'reverseImageEngine': reverseImageEngine.name,
    };
  }

  static DownloadDestination _readDestination(
    Map<String, dynamic> json,
    DownloadDestination fallback,
  ) {
    if (json.containsKey('destinationKind')) {
      return DownloadDestination.fromJson(json, fallback: fallback);
    }
    // Legacy schema v2 stored savePath/saveFolder with no producer and no
    // verifiable semantics. The safe migration is the built-in album; the
    // settings page surfaces the visible state so users can re-choose.
    return fallback;
  }

  static NamingRule _readNamingRule(
    Map<String, dynamic> json,
    Object? legacyNaming,
    NamingRule fallback,
  ) {
    final rawPreset = json['namingPreset'];
    if (rawPreset != null) {
      final preset = NamingPreset.fromCode(rawPreset);
      if (preset != NamingPreset.custom) {
        return NamingRule(preset: preset);
      }
      final template = json['namingTemplate'];
      if (template is String && NamingRule.isValidTemplate(template)) {
        return NamingRule(preset: NamingPreset.custom, template: template);
      }
      // A saved custom preset with an invalid template falls back to the
      // caller's default rather than silently switching to another preset.
      return fallback;
    }
    // Legacy namingRule string survives only when it is a valid bounded
    // template; anything else falls back to the default preset.
    if (legacyNaming is String && NamingRule.isValidTemplate(legacyNaming)) {
      return NamingRule(preset: NamingPreset.custom, template: legacyNaming);
    }
    return fallback;
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

  /// `fromHost` misses only for a persisted custom prefix — fromJson has
  /// already normalized or rejected it, so the null branch is [custom].
  ImageSourceMode get imageSourceMode =>
      ImageSourceMode.fromHost(imageSource) ?? ImageSourceMode.custom;

  TranslationProvider get translationProvider =>
      TranslationProvider.fromCode(translateIndex) ??
      TranslationProvider.disabled;

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
    Object? customImageSource = _unset,
    bool? enableDoh,
    Object? dohEndpointOverride = _unset,
    String? echFrontHost,
    PreviewQuality? previewQuality,
    ViewQuality? viewQuality,
    DetailQuality? detailQuality,
    NetworkMode? networkMode,
    bool? enableHistory,
    bool? enablePixivHistory,
    bool? enableLocalBlockR18,
    bool? enableLocalBlockAI,
    bool? hideMuted,
    bool? reduceMotion,
    int? translateIndex,
    int? maxDownloadCount,
    Object? downloadDestination = _unset,
    bool? downloadCaption,
    Object? namingRule = _unset,
    ReverseImageEngine? reverseImageEngine,
  }) {
    return AppSettings(
      schemaVersion: currentSchemaVersion,
      guideCompleted: guideCompleted ?? this.guideCompleted,
      languageTag: languageTag == null
          ? this.languageTag
          : canonicalLanguageTag(languageTag),
      themeCode: _theme(themeCode, this.themeCode),
      imageSource: imageSource != null && ImageMirror.isValidSource(imageSource)
          ? (ImageSourceMode.fromHost(imageSource) != null
                ? imageSource
                : ImageMirror.normalizeCustomSource(imageSource)!)
          : this.imageSource,
      customImageSource: identical(customImageSource, _unset)
          ? (imageSource != null &&
                    ImageSourceMode.fromHost(imageSource) == null &&
                    ImageMirror.normalizeCustomSource(imageSource) != null
                ? ImageMirror.normalizeCustomSource(imageSource)
                : this.customImageSource)
          : customImageSource as String?,
      enableDoh: enableDoh ?? this.enableDoh,
      dohEndpointOverride: identical(dohEndpointOverride, _unset)
          ? this.dohEndpointOverride
          : dohEndpointOverride as String?,
      echFrontHost: echFrontHost ?? this.echFrontHost,
      previewQuality: previewQuality ?? this.previewQuality,
      viewQuality: viewQuality ?? this.viewQuality,
      detailQuality: detailQuality ?? this.detailQuality,
      networkMode: networkMode ?? this.networkMode,
      enableHistory: enableHistory ?? this.enableHistory,
      enablePixivHistory: enablePixivHistory ?? this.enablePixivHistory,
      enableLocalBlockR18: enableLocalBlockR18 ?? this.enableLocalBlockR18,
      enableLocalBlockAI: enableLocalBlockAI ?? this.enableLocalBlockAI,
      hideMuted: hideMuted ?? this.hideMuted,
      reduceMotion: reduceMotion ?? this.reduceMotion,
      translateIndex:
          TranslationProvider.fromCode(translateIndex)?.code ??
          this.translateIndex,
      maxDownloadCount: _maxDownloads(maxDownloadCount, this.maxDownloadCount),
      downloadDestination: identical(downloadDestination, _unset)
          ? this.downloadDestination
          : downloadDestination as DownloadDestination,
      downloadCaption: downloadCaption ?? this.downloadCaption,
      namingRule: identical(namingRule, _unset)
          ? this.namingRule
          : namingRule as NamingRule,
      reverseImageEngine: reverseImageEngine ?? this.reverseImageEngine,
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
