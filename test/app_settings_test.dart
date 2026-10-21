import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/reverse_image/reverse_image_engine.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/settings/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/settings_world.dart';
import 'helpers/test_preferences.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

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
      final repository = FakeSettingsRepository(baseTestSettings())
        ..writeDelay = const Duration(milliseconds: 2);
      final container = ProviderContainer.test(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
      );
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
      expect(repository.saved, hasLength(4));

      repository.failWrites = true;
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
    final repository = FakeSettingsRepository(baseTestSettings());
    final container = ProviderContainer.test(
      overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
    );
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
    expect(repository.saved.last.searchIllustFilters, illust);
    expect(repository.saved.last.searchNovelFilters, novel);
  });

  test('networkModeCode round-trips and missing key defaults to automatic', () {
    final stored = baseTestSettings().copyWith(
      networkMode: NetworkMode.directOnly,
    );
    final encoded = stored.toJson();
    expect(encoded['networkModeCode'], NetworkMode.directOnly.code);
    final restored = AppSettings.fromJson(
      encoded,
      fallback: baseTestSettings(),
    );
    expect(restored.networkMode, NetworkMode.directOnly);

    final missing = AppSettings.fromJson({
      'guideCompleted': true,
      'languageTag': 'en-US',
      'themeCode': AppSettings.lightTheme,
    }, fallback: baseTestSettings());
    expect(missing.networkMode, NetworkMode.automatic);
  });

  test('reverseImageEngine round-trips and unknown values fall back', () {
    final stored = baseTestSettings().copyWith(
      reverseImageEngine: ReverseImageEngine.ascii2d,
    );
    final encoded = stored.toJson();
    expect(encoded['reverseImageEngine'], 'ascii2d');
    final restored = AppSettings.fromJson(
      encoded,
      fallback: baseTestSettings(),
    );
    expect(restored.reverseImageEngine, ReverseImageEngine.ascii2d);

    final unknown = AppSettings.fromJson({
      'reverseImageEngine': 'goggles',
    }, fallback: baseTestSettings());
    expect(unknown.reverseImageEngine, ReverseImageEngine.sauceNao);
    // A missing key keeps the explicit default for existing users.
    final missing = AppSettings.fromJson(
      const {},
      fallback: baseTestSettings(),
    );
    expect(missing.reverseImageEngine, ReverseImageEngine.sauceNao);
  });

  test('animationSpeed round-trips under the legacy key', () {
    final stored = baseTestSettings().copyWith(
      animationSpeed: AnimationSpeed.fast,
    );
    final encoded = stored.toJson();
    // The persisted key and codes predate the rename: no migration.
    expect(encoded['pageTransitionSpeedCode'], 250);
    final restored = AppSettings.fromJson(
      encoded,
      fallback: baseTestSettings(),
    );
    expect(restored.animationSpeed, AnimationSpeed.fast);
    final legacySlow = AppSettings.fromJson({
      'pageTransitionSpeedCode': 450,
    }, fallback: baseTestSettings());
    expect(legacySlow.animationSpeed, AnimationSpeed.slow);

    final unknown = AppSettings.fromJson({
      'pageTransitionSpeedCode': 999,
    }, fallback: baseTestSettings());
    expect(unknown.animationSpeed, AnimationSpeed.normal);
    // Missing key keeps the fallback's value; the explicit default is
    // normal for existing installs.
    final missing = AppSettings.fromJson(
      const {},
      fallback: baseTestSettings(),
    );
    expect(missing.animationSpeed, AnimationSpeed.normal);
    expect(AppSettings.defaults().animationSpeed, AnimationSpeed.normal);
  });

  test('a retired pageTransitionStyle key reads and is not written', () {
    final read = AppSettings.fromJson({
      'pageTransitionStyle': 'slide',
      'pressFeedback': false,
    }, fallback: baseTestSettings());
    expect(read.pressFeedback, isFalse);
    expect(read.toJson(), isNot(contains('pageTransitionStyle')));
  });

  test('feedDensity defaults to standard and round-trips by name', () {
    expect(AppSettings.defaults().feedDensity, FeedDensity.standard);
    for (final density in FeedDensity.values) {
      final encoded = baseTestSettings().copyWith(feedDensity: density);
      expect(
        AppSettings.fromJson(
          encoded.toJson(),
          fallback: baseTestSettings(),
        ).feedDensity,
        density,
      );
    }
    expect(
      AppSettings.fromJson({
        'feedDensity': 'dense',
      }, fallback: baseTestSettings()).feedDensity,
      FeedDensity.standard,
    );
  });

  test('animation speed factors scale from the normal tier', () {
    expect(AnimationSpeed.normal.factor, 1);
    expect(AnimationSpeed.fast.factor, closeTo(250 / 350, 1e-9));
    expect(AnimationSpeed.slow.factor, closeTo(450 / 350, 1e-9));
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

  test('legacy single searchFilters blob migrates into both type sets', () {
    final restored = AppSettings.fromJson({
      'searchFilters': {
        'target': 'title_and_caption',
        'sort': 'popular_female_desc',
        'bookmarkMin': 50,
        'ratio': 'square',
      },
    }, fallback: baseTestSettings());
    // The pre-typed default seeds the illust set as-is...
    expect(restored.searchIllustFilters.target, SearchTarget.titleAndCaption);
    expect(restored.searchIllustFilters.bookmarkMin, 50);
    expect(restored.searchIllustFilters.ratio, SearchRatioPattern.square);
    // ...and the novel set too, clamped into the novel-legal values.
    expect(
      restored.searchNovelFilters.target,
      SearchTarget.partialMatchForTags,
    );
    expect(restored.searchNovelFilters.sort, SearchSort.popularDesc);
    expect(restored.searchNovelFilters.bookmarkMin, 50);
  });

  test('legacy previewQuality true migrates to PreviewQuality.large', () {
    final settings = AppSettings.fromJson({
      'previewQuality': true,
    }, fallback: baseTestSettings());
    expect(settings.previewQuality, PreviewQuality.large);
  });

  test(
    'legacy scaleQuality bool migrates per R3 (true→original, false→large)',
    () {
      // `false → large` is the discriminating half: the type default is
      // `original`, so `true → original` alone would also pass if the legacy
      // key were ignored.
      final fromFalse = AppSettings.fromJson({
        'scaleQuality': false,
      }, fallback: baseTestSettings());
      expect(fromFalse.viewQuality, ViewQuality.large);

      final fromTrue = AppSettings.fromJson({
        'scaleQuality': true,
      }, fallback: baseTestSettings());
      expect(fromTrue.viewQuality, ViewQuality.original);
    },
  );

  test('plain settings JSON never contains translation credentials', () {
    final json = baseTestSettings().toJson();
    expect(json.keys, isNot(contains('translateAuthData')));
    expect(json.values, isNot(contains('access-token')));
    expect(AppSettings.translationCredentialRef.credentialKey, isNotEmpty);
  });

  test('hapticStrength defaults to standard and round-trips through JSON', () {
    final base = baseTestSettings();
    expect(base.hapticStrength, HapticStrength.standard);
    for (final strength in HapticStrength.values) {
      final json = base.copyWith(hapticStrength: strength).toJson();
      expect(json['hapticStrength'], strength.name);
      expect(json.containsKey('enableHaptics'), isFalse);
      expect(
        AppSettings.fromJson(json, fallback: baseTestSettings()).hapticStrength,
        strength,
      );
    }
  });

  test('the legacy haptics switch migrates to a strength', () {
    HapticStrength read(Map<String, dynamic> json) => AppSettings.fromJson(
      json,
      fallback: baseTestSettings().copyWith(
        hapticStrength: HapticStrength.light,
      ),
    ).hapticStrength;
    final legacy = baseTestSettings().toJson()..remove('hapticStrength');
    expect(read({...legacy, 'enableHaptics': false}), HapticStrength.off);
    expect(read({...legacy, 'enableHaptics': true}), HapticStrength.standard);
    // Neither key: the fallback wins.
    expect(read(legacy), HapticStrength.light);
    // The new key wins over a stale legacy one.
    expect(
      read({...legacy, 'enableHaptics': false, 'hapticStrength': 'strong'}),
      HapticStrength.strong,
    );
    // An unknown value is ignored like a missing key.
    expect(read({...legacy, 'hapticStrength': 'max'}), HapticStrength.light);
  });
}
