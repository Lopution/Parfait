import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings.dart';
import 'settings_repository.dart';

/// Error raised after a settings mutation failed to persist.
///
/// The controller leaves the previous [AppSettings] exposed, so callers can
/// show this error and the UI never claims a value that was not written.
class SettingsWriteException implements Exception {
  const SettingsWriteException(this.cause, this.stackTrace);

  final Object cause;
  final StackTrace stackTrace;

  @override
  String toString() => 'SettingsWriteException($cause)';
}

class SettingsController extends AsyncNotifier<AppSettings> {
  Future<void> _writeTail = Future<void>.value();
  late AppSettings _current;

  @override
  Future<AppSettings> build() async {
    final settings = await ref.watch(settingsRepositoryProvider).load();
    _current = settings;
    return settings;
  }

  /// Re-hydrates settings after a visible read failure.
  Future<void> reload() async {
    state = const AsyncLoading<AppSettings>();
    state = await AsyncValue.guard(build);
  }

  Future<void> selectLanguage(String languageTag) =>
      _update((settings) => settings.copyWith(languageTag: languageTag));

  Future<void> selectTheme(int themeCode) {
    if (![
      AppSettings.darkTheme,
      AppSettings.lightTheme,
      AppSettings.systemTheme,
    ].contains(themeCode)) {
      throw ArgumentError.value(themeCode, 'themeCode');
    }
    return _update((settings) => settings.copyWith(themeCode: themeCode));
  }

  Future<void> completeGuide() =>
      _update((settings) => settings.copyWith(guideCompleted: true));

  Future<void> selectImageSource(String imageSource) {
    if (ImageSourceMode.fromHost(imageSource) == null) {
      throw ArgumentError.value(imageSource, 'imageSource');
    }
    return _update((settings) => settings.copyWith(imageSource: imageSource));
  }

  Future<void> setPreviewQuality(bool enabled) =>
      _update((settings) => settings.copyWith(previewQuality: enabled));

  Future<void> setDohEnabled(bool enabled) =>
      _update((settings) => settings.copyWith(enableDoh: enabled));

  Future<void> setEchFrontHost(String value) => _update(
    (settings) => settings.copyWith(
      echFrontHost: value.trim().isEmpty
          ? AppSettings.defaultEchFrontHost
          : value.trim(),
    ),
  );

  Future<void> setInsecureNoSniEnabled(bool enabled) =>
      _update((settings) => settings.copyWith(insecureNoSniEnabled: enabled));

  Future<void> setNativeWebViewIntercept(bool enabled) =>
      _update((settings) => settings.copyWith(nativeWebViewIntercept: enabled));

  Future<void> setDohEndpointOverride(String? value) => _update(
    (settings) => settings.copyWith(
      dohEndpointOverride: value == null || value.trim().isEmpty
          ? null
          : value.trim(),
    ),
  );

  Future<void> setScaleQuality(bool enabled) =>
      _update((settings) => settings.copyWith(scaleQuality: enabled));

  Future<void> setHistoryEnabled(bool enabled) =>
      _update((settings) => settings.copyWith(enableHistory: enabled));

  Future<void> setPixivHistoryEnabled(bool enabled) =>
      _update((settings) => settings.copyWith(enablePixivHistory: enabled));

  Future<void> setLocalBlockR18(bool enabled) =>
      _update((settings) => settings.copyWith(enableLocalBlockR18: enabled));

  Future<void> setLocalBlockAI(bool enabled) =>
      _update((settings) => settings.copyWith(enableLocalBlockAI: enabled));

  Future<void> selectTranslationProvider(TranslationProvider provider) =>
      _update((settings) => settings.copyWith(translateIndex: provider.code));

  Future<void> setMaxDownloadCount(int count) {
    if (count < 1 || count > 10) {
      throw ArgumentError.value(count, 'count', 'must be between 1 and 10');
    }
    return _update((settings) => settings.copyWith(maxDownloadCount: count));
  }

  Future<void> setSavePath(String? path) =>
      _update((settings) => settings.copyWith(savePath: path));

  Future<void> setSaveFolder(String? folder) =>
      _update((settings) => settings.copyWith(saveFolder: folder));

  Future<void> setNamingRule(String? rule) =>
      _update((settings) => settings.copyWith(namingRule: rule));

  Future<void> _update(AppSettings Function(AppSettings) transform) {
    final operation = _writeTail.then((_) async {
      final candidate = transform(_current);
      try {
        await ref.read(settingsRepositoryProvider).save(candidate);
      } on Object catch (error, stackTrace) {
        throw SettingsWriteException(error, stackTrace);
      }
      _current = candidate;
      state = AsyncData(candidate);
    });
    // A failed write must not poison later independent writes. The failed
    // operation itself is still returned to the caller and remains visible.
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }
}

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return PreferencesSettingsRepository();
});

final settingsProvider = AsyncNotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

// Fine-grained typed providers are the only dependency surface consumers
// need. During startup they expose the same safe defaults as AppSettings.
final themeModeProvider = Provider<ThemeMode>((ref) {
  return ref.watch(
    settingsProvider.select(
      (async) => async.value?.themeMode ?? ThemeMode.system,
    ),
  );
});

final imageSourceProvider = Provider<ImageSourceMode>((ref) {
  return ref.watch(
    settingsProvider.select(
      (async) => async.value?.imageSourceMode ?? ImageSourceMode.normal,
    ),
  );
});

final previewQualityProvider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select((async) => async.value?.previewQuality ?? true),
  );
});

final scaleQualityProvider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select((async) => async.value?.scaleQuality ?? true),
  );
});

final localHistoryEnabledProvider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select((async) => async.value?.enableHistory ?? true),
  );
});

final pixivHistoryEnabledProvider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select((async) => async.value?.enablePixivHistory ?? true),
  );
});

final localBlockR18Provider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select(
      (async) => async.value?.enableLocalBlockR18 ?? false,
    ),
  );
});

final localBlockAIProvider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select(
      (async) => async.value?.enableLocalBlockAI ?? false,
    ),
  );
});

final translationProvider = Provider<TranslationProvider>((ref) {
  return ref.watch(
    settingsProvider.select(
      (async) => async.value?.translationProvider ?? TranslationProvider.google,
    ),
  );
});

final maxDownloadCountProvider = Provider<int>((ref) {
  return ref.watch(
    settingsProvider.select(
      (async) =>
          async.value?.maxDownloadCount ?? AppSettings.defaultMaxDownloadCount,
    ),
  );
});

/// Whether the strict network tier may use DoH.
final dohEnabledProvider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select((async) => async.value?.enableDoh ?? true),
  );
});

/// Effective DoH endpoint list: the user override (comma-separated) when
/// set, otherwise the built-in IP-literal endpoints.
final dohEndpointsProvider = Provider<List<String>>((ref) {
  final override = ref.watch(
    settingsProvider.select(
      (async) => async.value?.dohEndpointOverride,
    ),
  );
  if (override == null) return AppSettings.defaultDohEndpoints;
  return override
      .split(',')
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList(growable: false);
});

/// ECH front host (HTTPS RR query target for ECH config).
final echFrontHostProvider = Provider<String>((ref) {
  return ref.watch(
    settingsProvider.select(
      (async) => async.value?.echFrontHost ?? AppSettings.defaultEchFrontHost,
    ),
  );
});

/// Whether the user explicitly enabled the `insecureNoSni` fallback tier.
final insecureNoSniEnabledProvider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select(
      (async) => async.value?.insecureNoSniEnabled ?? false,
    ),
  );
});

/// R7: login WebView uses the native interception PlatformView on Android.
final nativeWebViewInterceptProvider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select(
      (async) => async.value?.nativeWebViewIntercept ?? false,
    ),
  );
});
