import 'dart:convert';
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/reverse_image/reverse_image_engine.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/keyboard_heights.dart';
import 'package:parfait/core/settings/preference_keys.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/settings/settings_repository.dart';
import 'package:parfait/core/settings/shared_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/settings_world.dart';
import 'helpers/test_preferences.dart';

void main() {
  test('defaults use safe modern values and beta56 setting names', () {
    final settings = AppSettings.defaults();
    expect(settings.guideCompleted, isFalse);
    expect(settings.themeCode, AppSettings.systemTheme);
    expect(settings.imageSource, AppSettings.defaultImageSource);
    expect(settings.previewQuality, PreviewQuality.medium);
    expect(settings.viewQuality, ViewQuality.original);
    expect(settings.enableHistory, isTrue);
    expect(settings.enablePixivHistory, isTrue);
    expect(settings.enableLocalBlockR18, isFalse);
    expect(settings.enableLocalBlockAI, isFalse);
    expect(settings.translateIndex, 1);
    expect(settings.maxDownloadCount, 3);
  });

  test('corrupt fields fall back independently and valid fields survive', () {
    final settings = AppSettings.fromJson({
      'guideCompleted': true,
      'languageTag': 'ja_JP',
      'themeCode': 99,
      'imageSource': 'unapproved-image-host.example',
      'previewQuality': false,
      'scaleQuality': 'broken',
      'enableHistory': false,
      'maxDownloadCount': 100,
      'namingRule': 'artist_{id}',
      'translateIndex': 99,
    }, fallback: baseTestSettings());

    expect(settings.guideCompleted, isTrue);
    expect(settings.languageTag, 'ja-JP');
    expect(settings.themeCode, AppSettings.lightTheme);
    expect(settings.imageSource, AppSettings.normalImageSource);
    expect(settings.previewQuality, PreviewQuality.medium);
    expect(settings.viewQuality, ViewQuality.original);
    expect(settings.enableHistory, isFalse);
    expect(settings.maxDownloadCount, 3);
    expect(settings.namingRule.preset, NamingPreset.custom);
    expect(settings.namingRule.template, 'artist_{id}');
    expect(settings.translateIndex, 1);
  });

  test('ranking and bottom-bar arrangements round-trip; damage falls back', () {
    final saved = baseTestSettings().copyWith(
      illustRankingArrangement: [(id: 'week', visible: true)],
      illustRankingLastMode: 'week',
      homeArrangement: [(id: 'ranking', visible: true)],
      homeStartPage: 'last',
      lastHomeDestination: 'search',
    );
    final json = jsonDecode(jsonEncode(saved.toJson())) as Map<String, Object?>;
    final restored = AppSettings.fromJson(json, fallback: baseTestSettings());
    expect(restored.illustRankingArrangement, [(id: 'week', visible: true)]);
    expect(restored.illustRankingLastMode, 'week');
    expect(restored.novelRankingArrangement, isNull);
    expect(restored.homeArrangement, [(id: 'ranking', visible: true)]);
    expect(restored.homeStartPage, 'last');
    expect(restored.lastHomeDestination, 'search');

    final damaged = AppSettings.fromJson({
      'illustRankingArrangement': 'broken',
      'novelRankingArrangement': null,
      'illustRankingLastMode': 3,
      'homeArrangement': 'broken',
      'homeStartPage': 3,
    }, fallback: saved);
    expect(damaged.illustRankingArrangement, saved.illustRankingArrangement);
    expect(damaged.novelRankingArrangement, isNull, reason: 'null resets');
    expect(damaged.illustRankingLastMode, 'week');
    expect(damaged.homeArrangement, saved.homeArrangement);
    expect(damaged.homeStartPage, 'last');
  });

  test('legacy individual keys migrate to the versioned JSON key', () async {
    final preferences = SharedPreferencesAsync();
    await preferences.setBool(
      PreferencesSettingsRepository.legacyGuideKey,
      true,
    );
    await preferences.setString(
      PreferencesSettingsRepository.legacyLanguageKey,
      'ru_RU',
    );
    await preferences.setInt(
      PreferencesSettingsRepository.legacyThemeKey,
      AppSettings.darkTheme,
    );

    final repository = PreferencesSettingsRepository(preferences: preferences);
    final settings = await repository.load();
    expect(settings.guideCompleted, isTrue);
    expect(settings.languageTag, 'ru-RU');
    expect(settings.themeCode, AppSettings.darkTheme);
    final stored =
        jsonDecode(
              (await preferences.getString(
                PreferencesSettingsRepository.settingsKey,
              ))!,
            )
            as Map<String, dynamic>;
    expect(stored['schemaVersion'], AppSettings.currentSchemaVersion);
  });

  test('a valid field survives a malformed field in versioned JSON', () async {
    final preferences = SharedPreferencesAsync();
    await preferences.setString(
      PreferencesSettingsRepository.settingsKey,
      jsonEncode({
        'schemaVersion': AppSettings.currentSchemaVersion,
        'guideCompleted': true,
        'languageTag': 'en-US',
        'themeCode': 'not-an-int',
        'maxDownloadCount': 7,
        'translateIndex': 42,
      }),
    );

    final settings = await PreferencesSettingsRepository(
      preferences: preferences,
    ).load();
    expect(settings.guideCompleted, isTrue);
    expect(settings.languageTag, 'en-US');
    expect(settings.themeCode, AppSettings.systemTheme);
    expect(settings.maxDownloadCount, 7);
    expect(settings.translateIndex, 1);
  });

  test(
    'controller serializes writes and exposes the old value on failure',
    () async {
      final preferences = GatedPreferences();
      installPreferencesForTest(preferences);
      await seedSettings(baseTestSettings());
      final container = ProviderContainer.test();
      final controller = container.read(settingsProvider.notifier);
      await container.read(settingsProvider.future);

      await Future.wait([
        controller.selectTheme(AppSettings.darkTheme),
        controller.setMaxDownloadCount(7),
        controller.setDohEnabled(false),
        controller.setDohEndpointOverride('https://9.9.9.9/dns-query'),
      ]);
      final state = container.read(settingsProvider).requireValue;
      expect(state.themeCode, AppSettings.darkTheme);
      expect(state.maxDownloadCount, 7);
      expect(state.enableDoh, isFalse);
      expect(state.dohEndpointOverride, 'https://9.9.9.9/dns-query');
      // Each write starts from the one before: none is lost on disk.
      final stored = await storedSettings().load();
      expect(stored.themeCode, AppSettings.darkTheme);
      expect(stored.maxDownloadCount, 7);
      expect(stored.enableDoh, isFalse);
      expect(stored.dohEndpointOverride, 'https://9.9.9.9/dns-query');

      preferences.writeGate = Future<void>.error(StateError('disk full'))
        ..ignore();
      await expectLater(
        controller.setPreviewQuality(PreviewQuality.medium),
        throwsA(isA<SettingsWriteException>()),
      );
      expect(
        container.read(settingsProvider).requireValue.previewQuality,
        PreviewQuality.medium,
      );
    },
  );

  test('setSearchFilters persists each type set independently', () async {
    await seedSettings(baseTestSettings());
    final container = ProviderContainer.test();
    await container.read(settingsProvider.future);

    const illust = IllustSearchFilters(
      sort: SearchSort.popularDesc,
      bookmarkMin: 500,
    );
    const novel = NovelSearchFilters(originalOnly: true);
    await container.read(settingsProvider.notifier).setSearchFilters(illust);
    await container.read(settingsProvider.notifier).setSearchFilters(novel);

    expect(container.read(searchIllustFiltersProvider), illust);
    expect(container.read(searchNovelFiltersProvider), novel);
    // Each write leaves the other type untouched.
    final stored = await storedSettings().load();
    expect(stored.searchIllustFilters, illust);
    expect(stored.searchNovelFilters, novel);
  });

  test('each option is stored under its key and read back; a damaged or '
      'missing value keeps the previous choice', () {
    _expectStored(
      'networkModeCode',
      read: (s) => s.networkMode,
      write: (s, v) => s.copyWith(networkMode: v),
      initial: NetworkMode.automatic,
      stored: [
        (NetworkMode.automatic, 0),
        (NetworkMode.directOnly, 1),
        (NetworkMode.compatPrefer, 2),
      ],
      damaged: 9,
    );
    _expectStored(
      'reverseImageEngine',
      read: (s) => s.reverseImageEngine,
      write: (s, v) => s.copyWith(reverseImageEngine: v),
      initial: ReverseImageEngine.sauceNao,
      stored: [
        (ReverseImageEngine.sauceNao, 'sauceNao'),
        (ReverseImageEngine.iqdb, 'iqdb'),
        (ReverseImageEngine.ascii2d, 'ascii2d'),
        (ReverseImageEngine.tinEye, 'tinEye'),
      ],
      damaged: 'goggles',
    );
    // The speed keeps the page-transition key and its millisecond codes, so
    // older payloads need no migration. An unknown code reads as normal.
    _expectStored(
      'pageTransitionSpeedCode',
      read: (s) => s.animationSpeed,
      write: (s, v) => s.copyWith(animationSpeed: v),
      initial: AnimationSpeed.normal,
      stored: [
        (AnimationSpeed.fast, 250),
        (AnimationSpeed.normal, 350),
        (AnimationSpeed.slow, 450),
      ],
      damaged: 999,
      damagedReads: AnimationSpeed.normal,
    );
    _expectStored(
      'feedDensity',
      read: (s) => s.feedDensity,
      write: (s, v) => s.copyWith(feedDensity: v),
      initial: FeedDensity.standard,
      stored: [
        (FeedDensity.compact, 'compact'),
        (FeedDensity.standard, 'standard'),
        (FeedDensity.comfortable, 'comfortable'),
      ],
      damaged: 'dense',
    );
    _expectStored(
      'hapticStrength',
      read: (s) => s.hapticStrength,
      write: (s, v) => s.copyWith(hapticStrength: v),
      initial: HapticStrength.standard,
      stored: [
        (HapticStrength.off, 'off'),
        (HapticStrength.light, 'light'),
        (HapticStrength.standard, 'standard'),
        (HapticStrength.strong, 'strong'),
      ],
      damaged: 'max',
    );
    _expectStored(
      'reduceMotion',
      read: (s) => s.reduceMotion,
      write: (s, v) => s.copyWith(reduceMotion: v),
      initial: false,
      stored: [(false, false), (true, true)],
      damaged: 'yes',
    );
  });

  test('typed search filters round-trip and damaged fields fall back', () {
    const filters = IllustSearchFilters(
      target: SearchTarget.exactMatchForTags,
      sort: SearchSort.popularDesc,
      duration: SearchDuration.week,
      aiFilter: SearchAiFilter.exclude,
      bookmarkMin: 100,
      bookmarkMax: 5000,
      ratio: SearchRatioPattern.portrait,
      contentType: SearchContentType.illust,
      widthMin: 800,
      heightMin: 600,
    );
    final stored = baseTestSettings().copyWith(
      searchIllustFilters: filters,
      searchNovelFilters: const NovelSearchFilters(
        target: SearchTarget.text,
        textLengthMin: 1000,
        originalOnly: true,
      ),
    );
    final restored = AppSettings.fromJson(
      stored.toJson(),
      fallback: baseTestSettings(),
    );
    expect(restored.searchIllustFilters, filters);
    expect(restored.searchNovelFilters.target, SearchTarget.text);
    expect(restored.searchNovelFilters.textLengthMin, 1000);
    expect(restored.searchNovelFilters.originalOnly, isTrue);

    // Custom date bounds also survive.
    final dated = baseTestSettings().copyWith(
      searchIllustFilters: IllustSearchFilters(
        startDate: DateTime(2024, 1, 10),
        endDate: DateTime(2024, 2, 10),
      ),
    );
    final datedRestored = AppSettings.fromJson(
      dated.toJson(),
      fallback: baseTestSettings(),
    );
    expect(datedRestored.searchIllustFilters.startDate, DateTime(2024, 1, 10));
    expect(datedRestored.searchIllustFilters.endDate, DateTime(2024, 2, 10));

    // One damaged field falls back without discarding valid siblings.
    final damaged = AppSettings.fromJson({
      'searchIllustFilters': {
        'target': 'bogus_target',
        'sort': 'date_asc',
        'bookmarkMin': 'not-a-number',
        'aiFilter': 'exclude',
      },
    }, fallback: baseTestSettings());
    expect(
      damaged.searchIllustFilters.target,
      SearchTarget.partialMatchForTags,
    );
    expect(damaged.searchIllustFilters.sort, SearchSort.dateAsc);
    expect(damaged.searchIllustFilters.bookmarkMin, isNull);
    expect(damaged.searchIllustFilters.aiFilter, SearchAiFilter.exclude);

    // A foreign target clamps into the type's own options.
    final foreign = AppSettings.fromJson({
      'searchNovelFilters': {'target': 'title_and_caption'},
      'searchIllustFilters': {'target': 'text'},
    }, fallback: baseTestSettings());
    expect(foreign.searchNovelFilters.target, SearchTarget.partialMatchForTags);
    expect(
      foreign.searchIllustFilters.target,
      SearchTarget.partialMatchForTags,
    );

    // A missing/non-map value keeps the defaults.
    expect(
      AppSettings.fromJson(
        const {},
        fallback: baseTestSettings(),
      ).searchIllustFilters,
      IllustSearchFilters.defaults,
    );
    expect(
      AppSettings.fromJson(const {
        'searchNovelFilters': 42,
      }, fallback: baseTestSettings()).searchNovelFilters,
      NovelSearchFilters.defaults,
    );
  });

  test('values saved by older versions carry over; retired keys are never '
      'written', () {
    // `before` differs from every expected value, so a row whose old key
    // were ignored would fail.
    final before = baseTestSettings().copyWith(
      viewQuality: ViewQuality.medium,
      hapticStrength: HapticStrength.light,
    );
    const blob = {
      'target': 'title_and_caption',
      'sort': 'popular_female_desc',
      'bookmarkMin': 50,
      'ratio': 'square',
    };
    final rows =
        <(Map<String, Object?>, Object? Function(AppSettings), Object)>[
          (
            {'previewQuality': true},
            (s) => s.previewQuality,
            PreviewQuality.large,
          ),
          ({'scaleQuality': true}, (s) => s.viewQuality, ViewQuality.original),
          ({'scaleQuality': false}, (s) => s.viewQuality, ViewQuality.large),
          (
            {'enableHaptics': false},
            (s) => s.hapticStrength,
            HapticStrength.off,
          ),
          (
            {'enableHaptics': true},
            (s) => s.hapticStrength,
            HapticStrength.standard,
          ),
          // The new key wins over a stale old one.
          (
            {'enableHaptics': false, 'hapticStrength': 'strong'},
            (s) => s.hapticStrength,
            HapticStrength.strong,
          ),
          // The single filter blob seeds both types; the novel set clamps it
          // into its own targets and sorts.
          (
            {'searchFilters': blob},
            (s) => s.searchIllustFilters,
            const IllustSearchFilters(
              target: SearchTarget.titleAndCaption,
              sort: SearchSort.popularFemaleDesc,
              bookmarkMin: 50,
              ratio: SearchRatioPattern.square,
            ),
          ),
          (
            {'searchFilters': blob},
            (s) => s.searchNovelFilters,
            const NovelSearchFilters(
              sort: SearchSort.popularDesc,
              bookmarkMin: 50,
            ),
          ),
          // A payload with the retired transition style still reads the rest.
          (
            {'pageTransitionStyle': 'slide', 'pressFeedback': false},
            (s) => s.pressFeedback,
            false,
          ),
        ];
    for (final (json, read, expected) in rows) {
      expect(
        read(AppSettings.fromJson(json, fallback: before)),
        expected,
        reason: '$json',
      );
    }
    expect(
      before.toJson().keys,
      isNot(
        anyOf([
          for (final key in const [
            'previewQuality',
            'scaleQuality',
            'enableHaptics',
            'searchFilters',
            'pageTransitionStyle',
          ])
            contains(key),
        ]),
      ),
    );
  });

  test('preferences that fail leave keyboard heights and developer options '
      'to this run', () async {
    final preferences = _BrokenPreferences();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    const screen = Size(400, 800);

    expect(container.read(developerOptionsProvider), isFalse);
    container.read(keyboardHeightsProvider.notifier).record(screen, 300);
    await pumpEventQueue();

    expect(
      container.read(keyboardHeightsProvider.notifier).heightFor(screen),
      300,
    );
    expect(container.read(developerOptionsProvider), isFalse);
    expect(preferences.calls, [
      'getBool ${PreferenceKeys.developerOptions}',
      'getString ${PreferenceKeys.keyboardHeights}',
      'setString ${PreferenceKeys.keyboardHeights}',
    ]);
  });

  test('plain settings JSON never contains translation credentials', () {
    final json = baseTestSettings().toJson();
    expect(json.keys, isNot(contains('translateAuthData')));
    expect(json.values, isNot(contains('access-token')));
    expect(AppSettings.translationCredentialRef.credentialKey, isNotEmpty);
  });
}

/// Checks how one option is stored: its default, each value written under
/// [key] as [stored] lists it and read back over another choice, and that a
/// [damaged] value or a missing key keeps the previous choice
/// ([damagedReads] when a damaged value resets the option instead).
void _expectStored<T extends Object>(
  String key, {
  required T Function(AppSettings) read,
  required AppSettings Function(AppSettings, T) write,
  required T initial,
  required List<(T, Object)> stored,
  required Object damaged,
  T? damagedReads,
}) {
  expect(read(AppSettings.defaults()), initial, reason: '$key default');
  T otherThan(T value) => stored.map((e) => e.$1).firstWhere((v) => v != value);
  for (final (value, raw) in stored) {
    expect(write(baseTestSettings(), value).toJson()[key], raw, reason: key);
    final over = write(baseTestSettings(), otherThan(value));
    expect(
      read(AppSettings.fromJson({key: raw}, fallback: over)),
      value,
      reason: '$key $raw',
    );
  }
  final previous = otherThan(initial);
  final before = write(baseTestSettings(), previous);
  expect(
    read(AppSettings.fromJson({key: damaged}, fallback: before)),
    damagedReads ?? previous,
    reason: '$key $damaged',
  );
  expect(
    read(AppSettings.fromJson(const {}, fallback: before)),
    previous,
    reason: '$key missing',
  );
}

class _BrokenPreferences extends SharedPreferencesAsync {
  /// Each call, as `method key`.
  final calls = <String>[];

  Future<T> _fail<T>(String call) {
    calls.add(call);
    return Future.error(StateError('broken'));
  }

  @override
  Future<bool?> getBool(String key) => _fail('getBool $key');

  @override
  Future<String?> getString(String key) => _fail('getString $key');

  @override
  Future<void> setString(String key, String value) => _fail('setString $key');
}
