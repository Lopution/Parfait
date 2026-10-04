import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_repository.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/account_transfer.dart';
import 'package:parfait/core/auth/account_transfer_service.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/comments/comment_translation.dart';
import 'package:parfait/core/comments/translation_credentials.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/network/compat/network_contracts.dart'
    show PixivDestinationRegistry;
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/download/download_destination.dart';
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/reverse_image/reverse_image_engine.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/settings/settings_repository.dart';
import 'package:parfait/core/platform/account_transfer_clipboard.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/core/user/user_repository.dart';
import 'package:parfait/features/history/history_page.dart' as history;
import 'package:parfait/features/login/login_page.dart';
import 'package:parfait/features/settings/network_settings_page.dart';
import 'package:parfait/features/settings/saf_tree_name.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/features/profile/user_page.dart' as profile;
import 'package:parfait/app/widgets/settings/settings_control.dart';
import 'package:parfait/app/widgets/settings/settings_group.dart';
import 'package:parfait/app/widgets/settings/settings_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/lookup.dart';
import 'package:parfait/l10n/app_localizations_zh.dart';
import 'package:parfait/app/motion/removal.dart';

import 'helpers/fake_account.dart';
import 'helpers/settings_world.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/test_preferences.dart';

class _AccountRepository implements AccountMetadataRepository {
  _AccountRepository([this.initial = const [], this.failLoad = false]);

  final List<Account> initial;
  final bool failLoad;

  @override
  Future<AccountMetadataSnapshot> load() async {
    if (failLoad) {
      throw AccountDataException('account metadata unavailable');
    }
    return AccountMetadataSnapshot(
      accounts: initial,
      currentId: initial.isEmpty ? null : initial.first.id,
    );
  }

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

/// Save gate for the switch-busy test: `save` parks on [gate] so the
/// widget layer's in-flight state is observable mid-switch.
class _BlockingAccountRepository extends FakeAccountMetadataRepository {
  _BlockingAccountRepository({required super.accounts, super.currentId});

  final Completer<void> gate = Completer<void>();

  @override
  Future<void> save(List<Account> next, String? nextCurrentId) async {
    await gate.future;
    return super.save(next, nextCurrentId);
  }
}

class _FakeProfileRepository implements UserRepository {
  @override
  Future<UserEntity> fetchDetail(
    int userId, {
    CancelToken? cancelToken,
  }) async => UserEntity(id: userId, name: 'tester', account: 'tester');

  @override
  Future<UserRelationPage> fetchRecommended({
    String? cursor,
    CancelToken? cancelToken,
  }) async => const UserRelationPage(users: [], nextUrl: null);

  @override
  bool validateRecommendedCursor({required String cursor}) => false;

  @override
  Future<UserIllustPage> fetchWorks(
    int userId, {
    required UserWorkType type,
    String? cursor,
    CancelToken? cancelToken,
  }) async => const UserIllustPage(illusts: [], nextUrl: null);

  @override
  Future<UserIllustPage> fetchBookmarks(
    int userId, {
    required UserRestrict restrict,
    String? tag,
    String? cursor,
    CancelToken? cancelToken,
  }) async => const UserIllustPage(illusts: [], nextUrl: null);

  @override
  bool validateWorksCursor(
    int userId, {
    required UserWorkType type,
    required String cursor,
  }) => false;

  @override
  bool validateBookmarksCursor(
    int userId, {
    required UserRestrict restrict,
    String? tag,
    required String cursor,
  }) => false;

  @override
  Future<UserRelationPage> fetchRelation(
    int userId, {
    required UserRelation relation,
    UserRestrict restrict = UserRestrict.public,
    String? cursor,
    CancelToken? cancelToken,
  }) async => const UserRelationPage(users: [], nextUrl: null);

  @override
  bool validateRelationCursor(
    int userId, {
    required UserRelation relation,
    required UserRestrict restrict,
    required String cursor,
  }) => false;
}

class _TransferClipboard implements TransferClipboard {
  String? text;
  int writeCount = 0;
  bool sensitiveMarkSupported = true;

  @override
  Future<void> write(String value, {required Duration clearAfter}) async {
    text = value;
    writeCount++;
  }

  @override
  Future<TransferClipboardContent?> read() async => null;

  @override
  Future<bool> clearIfCurrent(String fingerprint) async => false;

  @override
  Future<TransferClipboardCapabilities> capabilities() async =>
      TransferClipboardCapabilities(
        sensitiveMarkSupported: sensitiveMarkSupported,
      );
}

class _UnusedTransferVerifier implements TransferCredentialVerifier {
  @override
  Future<VerifiedTransferAccount> verify(TransferAccountPayload payload) {
    throw StateError('not used by export test');
  }
}

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
      final container = ProviderContainer(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
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

  test('setSearchFilters persists and the provider re-exposes it', () async {
    final repository = FakeSettingsRepository(baseTestSettings());
    final container = ProviderContainer(
      overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);

    const filters = SearchFilters(
      sort: SearchSort.popularDesc,
      bookmarkMin: 500,
    );
    await container.read(settingsProvider.notifier).setSearchFilters(filters);

    expect(container.read(searchFiltersProvider), filters);
    expect(repository.saved.single.searchFilters, filters);
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

  test('pressFeedback defaults on and round-trips', () {
    expect(AppSettings.defaults().pressFeedback, isTrue);
    final stored = baseTestSettings().copyWith(pressFeedback: false);
    final encoded = stored.toJson();
    expect(encoded['pressFeedback'], isFalse);
    expect(
      AppSettings.fromJson(encoded, fallback: baseTestSettings()).pressFeedback,
      isFalse,
    );
    final corrupt = AppSettings.fromJson({
      'pressFeedback': 'yes',
    }, fallback: baseTestSettings());
    expect(corrupt.pressFeedback, isTrue);
  });

  test('pageTransitionStyle defaults to system and round-trips by name', () {
    expect(
      AppSettings.defaults().pageTransitionStyle,
      PageTransitionStyle.system,
    );
    for (final style in PageTransitionStyle.values) {
      final encoded = baseTestSettings()
          .copyWith(pageTransitionStyle: style)
          .toJson();
      expect(encoded['pageTransitionStyle'], style.name);
      expect(
        AppSettings.fromJson(
          encoded,
          fallback: baseTestSettings(),
        ).pageTransitionStyle,
        style,
      );
    }
    final unknown = AppSettings.fromJson({
      'pageTransitionStyle': 'fadeThrough',
    }, fallback: baseTestSettings());
    expect(unknown.pageTransitionStyle, PageTransitionStyle.system);
  });

  test('animation speed factors scale from the normal tier', () {
    expect(AnimationSpeed.normal.factor, 1);
    expect(AnimationSpeed.fast.factor, closeTo(250 / 350, 1e-9));
    expect(AnimationSpeed.slow.factor, closeTo(450 / 350, 1e-9));
  });

  test('searchFilters round-trips and damaged fields fall back', () {
    const filters = SearchFilters(
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
    final stored = baseTestSettings().copyWith(searchFilters: filters);
    final restored = AppSettings.fromJson(
      stored.toJson(),
      fallback: baseTestSettings(),
    );
    expect(restored.searchFilters, filters);

    // Custom date bounds also survive.
    final dated = baseTestSettings().copyWith(
      searchFilters: SearchFilters(
        startDate: DateTime(2024, 1, 10),
        endDate: DateTime(2024, 2, 10),
      ),
    );
    final datedRestored = AppSettings.fromJson(
      dated.toJson(),
      fallback: baseTestSettings(),
    );
    expect(datedRestored.searchFilters.startDate, DateTime(2024, 1, 10));
    expect(datedRestored.searchFilters.endDate, DateTime(2024, 2, 10));

    // One damaged field falls back without discarding valid siblings.
    final damaged = AppSettings.fromJson({
      'searchFilters': {
        'target': 'bogus_target',
        'sort': 'date_asc',
        'bookmarkMin': 'not-a-number',
        'aiFilter': 'exclude',
      },
    }, fallback: baseTestSettings());
    expect(damaged.searchFilters.target, SearchTarget.partialMatchForTags);
    expect(damaged.searchFilters.sort, SearchSort.dateAsc);
    expect(damaged.searchFilters.bookmarkMin, isNull);
    expect(damaged.searchFilters.aiFilter, SearchAiFilter.exclude);

    // A missing/non-map value keeps the defaults.
    expect(
      AppSettings.fromJson(
        const {},
        fallback: baseTestSettings(),
      ).searchFilters,
      SearchFilters.defaults,
    );
    expect(
      AppSettings.fromJson(const {
        'searchFilters': 42,
      }, fallback: baseTestSettings()).searchFilters,
      SearchFilters.defaults,
    );
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

  test('all settings labels are available in all supported languages', () {
    const keys = [
      'homeMe',
      'motionSettings',
      'settingsBrowseHint',
      'accountSettings',
      'networkSettings',
      'networkMode',
      'networkModeHint',
      'networkModeListTitle',
      'networkModeAutomatic',
      'networkModeAutomaticHint',
      'networkModeDirectOnly',
      'networkModeDirectOnlyHint',
      'networkModeCompatPrefer',
      'networkModeCompatPreferHint',
      'networkEffectiveRoutes',
      'networkEffectiveRoutesEmpty',
      'networkRouteKindDirect',
      'networkRouteKindCompat',
      'networkThirdParty',
      'networkThirdPartyAuto',
      'networkThirdPartyHint',
      'networkReachable',
      'networkUnreachable',
      'networkChecking',
      'networkAdvanced',
      'networkAdvancedHint',
      'networkAdvancedReset',
      'networkAdvancedResetConfirm',
      'networkDoh',
      'networkDohHint',
      'networkDohEndpoints',
      'networkProbe',
      'networkProbeHint',
      'networkProbeRun',
      'networkProbeRunning',
      'networkProbeNotRun',
      'networkProbeCopied',
      'networkProbeOverview',
      'networkProbeWorst',
      'networkProbeDetails',
      'networkProbeNotPersisted',
      'networkProbeAdviceAllReachable',
      'networkProbeAdviceEchAvailable',
      'networkProbeAdviceNoSniAvailable',
      'networkProbeAdviceSniBlocked',
      'networkProbeAdviceDnsPolluted',
      'networkProbeAdviceIpBlackholed',
      'networkProbeAdviceAppLayer',
      'networkProbeAdviceInconclusive',
      'frameProbeTitle',
      'frameProbeHint',
      'frameProbeStart',
      'frameProbeStop',
      'frameProbeRecording',
      'frameProbeCapHint',
      'themeSettings',
      'languageSettings',
      'translateSettings',
      'browseSettings',
      'downloadSettings',
      'historySettings',
      'mutedItemsSettings',
      'downloaderSettings',
      'aboutSettings',
      'imageSourceNormal',
      'imageSourceAuto',
      'imageSourceAutoPending',
      'previewQuality',
      'viewQuality',
      'qualityMedium',
      'qualityLarge',
      'qualityOriginal',
      'scaleQuality',
      'localHistory',
      'pixivHistory',
      'blockR18',
      'blockAI',
      'maxDownloadCount',
      'namingRule',
      'saveLocation',
      'saveLocationAlbum',
      'saveLocationPixivAlbum',
      'saveLocationCustomAlbum',
      'saveLocationCustomAlbumHint',
      'saveLocationAlbumInvalid',
      'saveLocationSafFolder',
      'saveLocationSafFolderHint',
      'safStorageInternal',
      'saveLocationUriCopied',
      'namingPreset',
      'namingPresetId',
      'namingPresetArtistTitleId',
      'namingPresetTitleId',
      'namingPresetCustom',
      'namingTemplate',
      'namingTemplateHint',
      'namingTemplateInvalid',
      'namingPreview',
      'namingTemplateVariables',
      'save',
      'translateCredentialHint',
      'historySettingsHint',
      'aboutLicenseText',
      'accountTransferWarning',
      'accountTransferCopied',
      'accountTransferImported',
      'accountTransferClipboardReplaced',
      'accountTransferCorrupt',
      'accountTransferCredentialInvalid',
      'accountTransferVerificationUnavailable',
      'accountTransferNoAccount',
      'accountTransferCredentialUnavailable',
      'accountTransferClipboardUnavailable',
      'accountTransferStorageFailure',
      'settingsSummaryOn',
      'settingsSummaryOff',
      'settingsHistorySummary',
      'settingsMutedSummary',
      'settingsDownloadTasksSummary',
      'settingsCredentialConfigured',
      'settingsCredentialNotConfigured',
      'aboutUpdateOffline',
      'aboutUpdateRateLimited',
      'aboutUpdateInvalid',
      'aboutUpdateBusy',
      'aboutUpdateCanceled',
      'backupMergeHint',
      'backupOverwriteHint',
      'backupImportOverwriteConfirmTitle',
      'continueAction',
      // 'backupImportMergeConfirmTitle' is parameterized — the four-language
      // presence is compile-time enforced, l10nLookup skips placeholders.
    ];
    // Four-language presence is compile-time enforced by gen-l10n; this
    // smoke check keeps the transfer-error key list honest against zh.
    final zh = AppLocalizationsZh();
    for (final key in keys) {
      expect(l10nLookup(zh, key), isNotEmpty, reason: key);
    }
  });

  testWidgets('browse quality choices use typed segmented buttons', (
    tester,
  ) async {
    final repository = FakeSettingsRepository(baseTestSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: BrowseSettingsPage(),
        ),
      ),
    );
    // Tall surface: the source list above grew a row, and unmounted
    // off-viewport selectors must not shrink the segment assertions.
    tester.view.physicalSize = const Size(800, 3200);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();
    await tester.pump();
    final selectorFinder = find.byWidgetPredicate(
      (widget) =>
          widget is SegmentedButton<PreviewQuality> ||
          widget is SegmentedButton<DetailQuality> ||
          widget is SegmentedButton<ViewQuality>,
      skipOffstage: false,
    );
    final selectors = tester
        .widgetList<SegmentedButton<dynamic>>(selectorFinder)
        .toList();
    expect(selectors, hasLength(3));
    expect(selectors[0].segments.map((segment) => segment.value).toList(), [
      PreviewQuality.medium,
      PreviewQuality.large,
    ]);
    expect(selectors[1].segments.map((segment) => segment.value).toList(), [
      DetailQuality.large,
      DetailQuality.original,
    ]);
    expect(selectors[2].segments.map((segment) => segment.value).toList(), [
      ViewQuality.large,
      ViewQuality.original,
    ]);

    // The mirror section above pushes the quality selectors below the fold;
    // scroll each into view before tapping.
    await _scrollCentered(tester, selectorFinder.at(0));
    await tester.tap(
      find.descendant(of: selectorFinder.at(0), matching: find.text('大图')),
    );
    await tester.pumpAndSettle();
    expect(repository.value.previewQuality, PreviewQuality.large);

    await _scrollCentered(tester, selectorFinder.at(1));
    await tester.tap(
      find.descendant(of: selectorFinder.at(1), matching: find.text('原图')),
    );
    await tester.pumpAndSettle();
    expect(repository.value.detailQuality, DetailQuality.original);
  });

  Future<void> pumpMotion(
    WidgetTester tester,
    FakeSettingsRepository repository,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: MotionSettingsPage(),
        ),
      ),
    );
    tester.view.physicalSize = const Size(800, 3200);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();
    await tester.pump();
  }

  Finder speedSelector() => find.byWidgetPredicate(
    (widget) => widget is SegmentedButton<AnimationSpeed>,
    skipOffstage: false,
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('animation speed is a three-way picker on ${platform.name}', (
      tester,
    ) async {
      final repository = FakeSettingsRepository(baseTestSettings());
      debugDefaultTargetPlatformOverride = platform;
      try {
        await pumpMotion(tester, repository);

        final selector = speedSelector();
        expect(selector, findsOneWidget);
        await _scrollCentered(tester, selector);
        expect(find.text('动画速度'), findsOneWidget);
        expect(find.text('作用于应用内全部动画；水波纹等系统控件动画不受影响'), findsOneWidget);
        final segments = tester
            .widget<SegmentedButton<AnimationSpeed>>(selector)
            .segments
            .map((segment) => segment.value)
            .toList();
        expect(segments, AnimationSpeed.values);

        await tester.tap(
          find.descendant(of: selector, matching: find.text('慢')),
        );
        await tester.pumpAndSettle();
        expect(repository.value.animationSpeed, AnimationSpeed.slow);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('the page transition picker persists on ${platform.name}', (
      tester,
    ) async {
      final repository = FakeSettingsRepository(baseTestSettings());
      debugDefaultTargetPlatformOverride = platform;
      try {
        await pumpMotion(tester, repository);
        expect(find.text('页面转场', skipOffstage: false), findsOneWidget);
        for (final label in ['系统默认', '共享轴', '缩放', '侧滑']) {
          expect(find.text(label, skipOffstage: false), findsOneWidget);
        }
        expect(
          find.text(
            platform == TargetPlatform.android ? '安卓系统转场，支持预测性返回' : '平台默认',
            skipOffstage: false,
          ),
          findsOneWidget,
        );

        final slide = find.text('侧滑', skipOffstage: false);
        await _scrollCentered(tester, slide);
        await tester.tap(slide);
        await tester.pumpAndSettle();
        expect(repository.value.pageTransitionStyle, PageTransitionStyle.slide);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('the press feedback switch persists', (tester) async {
    final repository = FakeSettingsRepository(baseTestSettings());
    await pumpMotion(tester, repository);
    final row = find.text('按压反馈', skipOffstage: false);
    await _scrollCentered(tester, row);
    expect(find.text('按下卡片时轻微缩小'), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(repository.value.pressFeedback, isFalse);
  });

  testWidgets('reduce motion greys the speed picker and explains why', (
    tester,
  ) async {
    final repository = FakeSettingsRepository(
      baseTestSettings().copyWith(reduceMotion: true),
    );
    await pumpMotion(tester, repository);

    await _scrollCentered(tester, speedSelector());
    final button = tester.widget<SegmentedButton<AnimationSpeed>>(
      speedSelector(),
    );
    expect(button.onSelectionChanged, isNull);
    expect(find.text('开启「减少动态效果」时不播放动画，速度不生效'), findsOneWidget);
  });

  testWidgets('settings primitives expose headings, values and actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SettingsGroup(
                title: Text('Display'),
                children: [
                  SettingsControl(
                    title: Text('Large previews'),
                    value: true,
                    onChanged: _ignoreBool,
                  ),
                  SettingsTile(
                    icon: Icons.info_outline,
                    title: 'About',
                    onTap: _noop,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Display'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Display')),
      isSemantics(isHeader: true),
    );
    expect(
      tester.getSemantics(find.byType(Switch)),
      isSemantics(hasToggledState: true, isToggled: true, hasTapAction: true),
    );
    expect(find.bySemanticsLabel('About'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('About')),
      isSemantics(isButton: true, hasTapAction: true),
    );
  });

  testWidgets('settings read failures expose a retryable UI', (tester) async {
    final repository = FakeSettingsRepository(
      baseTestSettings(),
      failLoad: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),

          home: ThemeSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-load-error')), findsOneWidget);
    expect(find.byKey(const Key('settings-load-retry')), findsOneWidget);
  });

  testWidgets('account read failures expose a retryable UI', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(baseTestSettings()),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            _AccountRepository(const [], true),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
        ],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),

          home: AccountSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-load-error')), findsOneWidget);
    expect(find.byKey(const Key('settings-load-retry')), findsOneWidget);
    expect(find.text('无账号'), findsNothing);
  });

  testWidgets('account summaries show the ID instead of the email', (
    tester,
  ) async {
    const account = Account(
      id: '42',
      userId: 42,
      name: 'tester',
      mailAddress: 'private@example.invalid',
    );
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh', 'CN'),
        home: Scaffold(body: AccountSummaryTile(account: account)),
      ),
    );
    expect(find.text('账号 ID: 42'), findsOneWidget);
    expect(find.text('private@example.invalid'), findsNothing);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(baseTestSettings()),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(
              accounts: const [account],
              currentId: account.id,
            ),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
        ],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: AccountSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('账号 ID: 42'), findsOneWidget);
    expect(find.text('private@example.invalid'), findsNothing);
  });

  testWidgets(
    'account switch spins the target row and disables the list mid-commit',
    (tester) async {
      final repository = _BlockingAccountRepository(
        accounts: const [
          Account(id: '1', userId: 1, name: 'first'),
          Account(id: '2', userId: 2, name: 'second'),
        ],
        currentId: '1',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(
              FakeSettingsRepository(baseTestSettings()),
            ),
            accountMetadataRepositoryProvider.overrideWithValue(repository),
            credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
          ],
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: AccountSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Account rows delete through the exit-first removal.
      expect(
        find.ancestor(
          of: find.widgetWithText(ListTile, 'first'),
          matching: find.byType(Removable),
        ),
        findsOneWidget,
      );

      // Current row: check icon + selected semantics, no tap target.
      final currentTile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'first'),
      );
      expect(currentTile.onTap, isNull);
      expect(currentTile.selected, isTrue);

      await tester.tap(find.text('second'));
      await tester.pump();

      // Busy: the target row spins (semantics label reads 正在切换) and
      // every row's tap/remove affordances are disabled while the
      // metadata commit is in flight.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, 'first')).onTap,
        isNull,
      );
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, 'second')).onTap,
        isNull,
      );
      expect(
        tester
            .widgetList<IconButton>(
              find.widgetWithIcon(IconButton, Icons.delete_outline),
            )
            .map((button) => button.onPressed),
        everyElement(isNull),
      );

      repository.gate.complete();
      await tester.pumpAndSettle();

      // After the commit the new current row carries the check and the
      // other row is tappable again.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(repository.currentId, '2');
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'second'))
            .selected,
        isTrue,
      );
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, 'first')).onTap,
        isNotNull,
      );
    },
  );

  testWidgets('settings home shows the Me tab groups and order', (
    tester,
  ) async {
    final repository = FakeSettingsRepository(baseTestSettings());
    // Tall surface so every lazily-built row exists for the text asserts.
    tester.view.physicalSize = const Size(800, 6400);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
        ],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),

          home: SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('账号管理'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('浏览设置'), findsOneWidget);
    // Hub layout: intent groups carry labeled section headers.
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('浏览'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('数据'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text('我的内容', skipOffstage: false), findsOneWidget);
    expect(find.text('历史记录', skipOffstage: false), findsOneWidget);
    expect(find.text('网络与下载'), findsOneWidget);
    expect(find.text('数据'), findsOneWidget);
    expect(find.text('下载任务'), findsOneWidget);
    expect(find.text('动效与触感', skipOffstage: false), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('新作'), findsNothing);
  });

  testWidgets('settings home opens with the account card alone', (
    tester,
  ) async {
    // Tall surface so every lazily-built row exists for position asserts.
    tester.view.physicalSize = const Size(800, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(baseTestSettings()),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
        ],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final groups = tester
        .widgetList<SettingsGroup>(find.byType(SettingsGroup))
        .toList();
    final first = find.byWidget(groups.first);
    // The account card is the whole first (untitled) group; account
    // management got its own 账号 group further down.
    expect(
      find.descendant(of: first, matching: find.byType(AccountSummaryTile)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: first, matching: find.byType(SettingsTile)),
      findsNothing,
    );

    // Content destinations lead the page, then account, then preferences.
    double dyOf(String text) => tester.getCenter(find.text(text)).dy;
    expect(dyOf('我的内容'), lessThan(dyOf('账号')));
    expect(dyOf('账号'), lessThan(dyOf('外观')));
    expect(dyOf('外观'), lessThan(dyOf('浏览')));
    expect(dyOf('浏览'), lessThan(dyOf('网络与下载')));
    expect(dyOf('网络与下载'), lessThan(dyOf('数据')));

    // Every group heading is a semantics header — the labelled groups use
    // SettingsGroup titles now, not styled plain text.
    for (final title in ['我的内容', '账号', '外观', '浏览', '网络与下载', '数据']) {
      await tester.scrollUntilVisible(
        find.text(title),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(
        tester.getSemantics(find.text(title)),
        isSemantics(isHeader: true),
      );
    }
  });

  testWidgets('backup page renders its hint below the action rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(baseTestSettings()),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: BackupSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final hintTop = tester
        .getTopLeft(find.text('导出当前设置、屏蔽列表和浏览历史；凭据不会写入文件。'))
        .dy;
    // The hint is the group's footnote: below both action rows, not above.
    for (final row in ['导出备份', '导入备份']) {
      expect(
        hintTop,
        greaterThan(
          tester.getBottomLeft(find.widgetWithText(ListTile, row)).dy,
        ),
      );
    }
    expect(
      tester.getSemantics(
        find.descendant(
          of: find.byType(SettingsGroup),
          matching: find.text('备份与导入'),
        ),
      ),
      isSemantics(isHeader: true),
    );
  });

  testWidgets('settings home shows current-value summaries', (tester) async {
    // Tall surface so every lazily-built row exists for the text asserts.
    tester.view.physicalSize = const Size(800, 6400);
    addTearDown(tester.view.resetPhysicalSize);
    PackageInfo.setMockInitialValues(
      appName: 'Parfait',
      packageName: 'io.github.lopution.parfait',
      version: '9.9.9',
      buildNumber: '99',
      buildSignature: '',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(baseTestSettings()),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
        ],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Every configuration entry shows its current value (D- summaries):
    // the signed-out state appears on the card and the account tile.
    expect(find.text('未登录'), findsNWidgets(2));
    // translateIndex=1 → disabled; credential-less providers show the
    // provider label alone ('关闭').
    for (final summary in [
      '明亮',
      'English',
      '关闭',
      '本地屏蔽、图片画质',
      '暂无屏蔽条目',
      '自动',
      '作品 ID（默认） · Parfait 相册（默认）',
      '0 个活动任务',
      '导出当前设置、屏蔽列表和浏览历史；凭据不会写入文件。',
      '9.9.9+99',
    ]) {
      expect(find.text(summary), findsOneWidget);
    }
  });

  testWidgets('translation entry reports the credential configured state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    final store = FakeTranslationStore()
      ..baidu = const BaiduTranslationCredentials(appId: 'id', secret: 'sec');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(
              baseTestSettings().copyWith(translateIndex: 2),
            ),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
          translationCredentialStoreProvider.overrideWithValue(store),
        ],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('百度翻译 · 已配置'), findsOneWidget);

    store.baidu = null;
    // The summary re-reads existence on the next build — rebuild the page
    // the same way returning from the credentials page would.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(
              baseTestSettings().copyWith(translateIndex: 2),
            ),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
          translationCredentialStoreProvider.overrideWithValue(store),
        ],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('百度翻译 · 未配置'), findsOneWidget);
  });

  testWidgets('translation summary re-probes when the provider switches', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    final store = FakeTranslationStore()
      ..baidu = const BaiduTranslationCredentials(appId: 'id', secret: 'sec');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(
              baseTestSettings().copyWith(translateIndex: 2),
            ),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
          translationCredentialStoreProvider.overrideWithValue(store),
        ],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('百度翻译 · 已配置'), findsOneWidget);

    // A provider switch reuses the summary State — the probe must
    // follow the new provider instead of showing baidu's stale 已配置
    // under the llm label.
    final element = tester.element(find.byType(SettingsPage));
    await ProviderScope.containerOf(element)
        .read(settingsProvider.notifier)
        .selectTranslationProvider(TranslationProvider.translationLlm);
    await tester.pumpAndSettle();

    expect(find.text('自定义 LLM（OpenAI 兼容） · 未配置'), findsOneWidget);
    expect(find.textContaining('已配置'), findsNothing);
  });

  testWidgets('translation summary re-probes when the root resurfaces', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    final store = FakeTranslationStore()
      ..baidu = const BaiduTranslationCredentials(appId: 'id', secret: 'sec');
    final router = createPixivRouter(initialLocation: '/settings');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(
              baseTestSettings().copyWith(translateIndex: 2),
            ),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
          translationCredentialStoreProvider.overrideWithValue(store),
        ],
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('百度翻译 · 已配置'), findsOneWidget);

    // Cover the root with the credentials route, clear the key behind
    // its back, then unwind: returning to the root must re-read
    // existence instead of keeping the covered-time snapshot.
    unawaited(router.push<void>('/settings/translate/credentials/baidu'));
    await tester.pumpAndSettle();
    store.baidu = null;
    router.pop();
    await tester.pumpAndSettle();

    expect(find.text('百度翻译 · 未配置'), findsOneWidget);
  });

  testWidgets(
    'translate page credential entry shows and refreshes configured state',
    (tester) async {
      final store = FakeTranslationStore()
        ..baidu = const BaiduTranslationCredentials(appId: 'id', secret: 'sec');
      final router = createPixivRouter(initialLocation: '/settings/translate');
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(
              FakeSettingsRepository(
                baseTestSettings().copyWith(translateIndex: 2),
              ),
            ),
            accountMetadataRepositoryProvider.overrideWithValue(
              FakeAccountMetadataRepository(),
            ),
            credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
            translationCredentialStoreProvider.overrideWithValue(store),
          ],
          child: MaterialApp.router(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The 凭据 entry under the selected provider reads 已配置.
      expect(find.text('已配置'), findsOneWidget);
      expect(find.text('未配置'), findsNothing);

      // Entering the credentials page and coming back re-reads existence:
      // a clear on the sub-page flips the entry to 未配置.
      await tester.tap(find.text('百度 AppID / 密钥'));
      await tester.pumpAndSettle();
      store.baidu = null;
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('未配置'), findsOneWidget);
    },
  );

  testWidgets(
    'download custom template disables save while invalid and guards drafts',
    (tester) async {
      final repository = FakeSettingsRepository(
        baseTestSettings().copyWith(
          namingRule: const NamingRule(
            preset: NamingPreset.custom,
            template: '{id}',
          ),
        ),
      );
      // Tall surface so the lazily-built template section exists.
      tester.view.physicalSize = const Size(800, 4000);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DownloadSettingsPage(),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The persisted valid template keeps save enabled; breaking it
      // disables the button and shows the error text.
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNotNull,
      );
      await tester.enterText(find.byType(TextField), 'plain-text');
      await tester.pump();
      expect(find.text('模板包含不支持的变量或非法字符'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );

      // Dirty draft: system back asks before leaving; 取消 keeps editing
      // and the uncommitted input survives the round trip.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(find.byType(DownloadSettingsPage), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'plain-text',
      );

      // 放弃 leaves the page and drops the draft.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(DownloadSettingsPage), findsNothing);
    },
  );

  testWidgets('save location album name draft asks before leaving', (
    tester,
  ) async {
    final repository = FakeSettingsRepository(baseTestSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DownloadDestinationPage(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // A clean form pops straight through without a prompt.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DownloadDestinationPage), findsNothing);

    // Dirty draft: system back asks; 取消 keeps the page and the input.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'my album');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadDestinationPage), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'my album',
    );

    // Committing the draft clears the guard — leaving then pops
    // without asking.
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DownloadDestinationPage), findsNothing);
    expect(repository.value.downloadDestination.customAlbumName, 'my album');
  });

  test('safTreeDisplayName decodes volumes and falls back honestly', () {
    final zh = AppLocalizationsZh();
    expect(
      safTreeDisplayName(
        zh,
        'content://com.android.externalstorage.documents/tree/primary%3ADownload%2Fpixiv',
      ),
      '内部存储/Download/pixiv',
    );
    expect(
      safTreeDisplayName(
        zh,
        'content://com.android.externalstorage.documents/tree/1234-5678%3ADCIM',
      ),
      'SD 卡（1234-5678）/DCIM',
    );
    // Storage root: no path suffix after the volume colon.
    expect(
      safTreeDisplayName(
        zh,
        'content://com.android.externalstorage.documents/tree/primary%3A',
      ),
      '内部存储',
    );
    // Desktop pickers return plain filesystem paths — verbatim.
    expect(
      safTreeDisplayName(zh, '/home/user/Pictures'),
      '/home/user/Pictures',
    );
    // Unparseable content URIs degrade to the raw string, never blank.
    expect(safTreeDisplayName(zh, 'content://x/tree'), 'content://x/tree');
    expect(safTreeDisplayName(zh, ''), '');
  });

  testWidgets('save location headlines the decoded SAF name, URI demoted', (
    tester,
  ) async {
    const uri =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload%2Fpixiv';
    final repository = FakeSettingsRepository(
      baseTestSettings().copyWith(
        downloadDestination: const DownloadDestination.safFolder(uri),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: DownloadDestinationPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The headline is the decoded name; the tile is the selected row.
    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '内部存储/Download/pixiv'),
    );
    expect(tile.selected, isTrue);

    // The raw `content://` identifier survives only in the truncated
    // subtitle (maxLines 1 + ellipsis), never as the headline.
    final subtitle = tester.widget<Text>(find.text(uri));
    expect(subtitle.maxLines, 1);
    expect(subtitle.overflow, TextOverflow.ellipsis);
  });

  testWidgets('download settings summary shows the decoded SAF name too', (
    tester,
  ) async {
    const uri =
        'content://com.android.externalstorage.documents/tree/1234-5678%3ADCIM';
    final repository = FakeSettingsRepository(
      baseTestSettings().copyWith(
        downloadDestination: const DownloadDestination.safFolder(uri),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: DownloadSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The save-location tile summary is the human name, not the URI.
    expect(find.text('SD 卡（1234-5678）/DCIM'), findsOneWidget);
    expect(find.textContaining('content://'), findsNothing);
  });

  testWidgets('the history tile opens the content route', (tester) async {
    final router = createPixivRouter(initialLocation: '/settings');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(baseTestSettings()),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
        ],
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    // The single 历史记录 tile under 我的内容 opens the history view.
    await tester.scrollUntilVisible(
      find.text('历史记录'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史记录'));
    await tester.pumpAndSettle();
    expect(find.byType(history.HistoryPage), findsOneWidget);
  });

  testWidgets('account card opens one profile route without a settings entry', (
    tester,
  ) async {
    final router = createPixivRouter(initialLocation: '/settings');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(baseTestSettings()),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(
              accounts: const [Account(id: '42', userId: 42, name: 'tester')],
              currentId: '42',
            ),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
          userRepositoryProvider.overrideWithValue(_FakeProfileRepository()),
        ],
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    // Compact surface: the wide rail's trailing settings gear is shell
    // chrome, not a profile-page settings entry.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    // The account name also renders as the account-tile summary — tap the
    // summary tile itself, not the ambiguous text.
    await tester.tap(find.byType(AccountSummaryTile));
    await tester.pumpAndSettle();

    expect(find.byType(profile.MePage), findsOneWidget);
    // The account route renders its own profile state here; whatever the
    // shell-level gear shows on /me does not leak into this pushed page.
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
  });

  testWidgets('a signed-out account card opens the login page', (tester) async {
    final router = createPixivRouter(initialLocation: '/settings');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(baseTestSettings()),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
        ],
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Signed out the card used to ignore taps — it is the login entry.
    await tester.tap(find.byType(AccountSummaryTile));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('the export tile exports bounded transfer data after confirm', (
    tester,
  ) async {
    final repository = FakeAccountMetadataRepository(
      accounts: const [Account(id: '42', userId: 42, name: 'tester')],
      currentId: '42',
    );
    final clipboard = _TransferClipboard();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(baseTestSettings()),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(repository),
          credentialStoreProvider.overrideWithValue(
            FakeCredentialStore(
              values: const {
                '42': Credential(
                  accessToken: 'access',
                  refreshToken: 'refresh',
                ),
              },
            ),
          ),
          accountTransferServiceProvider.overrideWith(
            (ref) => AccountTransferService(
              accountStore: ref.read(accountStoreProvider.notifier),
              credentialStore: ref.read(credentialStoreProvider),
              verifier: _UnusedTransferVerifier(),
              clipboard: clipboard,
            ),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),

          home: AccountSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出账号凭据'));
    await tester.pumpAndSettle();
    // The tile only opens the confirm dialog — nothing is exported yet.
    expect(clipboard.writeCount, 0);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(clipboard.writeCount, 1);
    expect(TransferEnvelope.parse(clipboard.text!), isA<TransferEnvelope>());
  });

  testWidgets(
    'exporting on a device without sensitive clipboard shows a warning',
    (tester) async {
      final repository = FakeAccountMetadataRepository(
        accounts: const [Account(id: '42', userId: 42, name: 'tester')],
        currentId: '42',
      );
      final clipboard = _TransferClipboard();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(
              FakeSettingsRepository(baseTestSettings()),
            ),
            accountMetadataRepositoryProvider.overrideWithValue(repository),
            credentialStoreProvider.overrideWithValue(
              FakeCredentialStore(
                values: const {
                  '42': Credential(
                    accessToken: 'access',
                    refreshToken: 'refresh',
                  ),
                },
              ),
            ),
            accountTransferServiceProvider.overrideWith(
              (ref) => AccountTransferService(
                accountStore: ref.read(accountStoreProvider.notifier),
                credentialStore: ref.read(credentialStoreProvider),
                verifier: _UnusedTransferVerifier(),
                clipboard: clipboard,
              ),
            ),
            // Capability override: emulate an Android <13 device that
            // cannot mark the clipboard entry as sensitive.
            transferClipboardProvider.overrideWithValue(
              _TransferClipboard()..sensitiveMarkSupported = false,
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),

            home: AccountSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('导出账号凭据'));
      await tester.pumpAndSettle();
      // Export is gated behind the warning dialog's confirm action.
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      // The copied-toast (4s) blocks the queued warning snackbar; advance
      // past it so the explicit security warning becomes visible.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // The explicit security warning appears (R4: 安全降级不能静默).
      expect(
        find.text(
          '此设备不支持敏感剪贴板标记（Android 13+ 才支持）：凭据将以明文进入系统剪贴板，请尽快粘贴；5 分钟后自动清除。',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('network advanced accepts hostname DoH endpoints', (
    tester,
  ) async {
    // Regression: the endpoint validator required IP-literal hosts, which
    // silently rejected the Cloudflare DoH domain defaults
    // (1dot1dot1dot1.cloudflare-dns.com) as soon as the user touched the
    // field. Domain endpoints are the production default now. DoH editing
    // lives on the advanced page (D3).
    final repository = FakeSettingsRepository(baseTestSettings());
    final router = createPixivRouter(initialLocation: '/settings/network');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
        ],
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The mode tiles and status sections push this entry below the fold.
    await tester.scrollUntilVisible(
      find.text('高级设置'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();

    // The default endpoints are domain-URL form.
    expect(
      find.textContaining('1dot1dot1dot1.cloudflare-dns.com'),
      findsWidgets,
    );
    // Replacing with another hostname endpoint must NOT show the error hint.
    await tester.enterText(
      find.byType(TextField).first,
      'https://dns.alidns.com/dns-query',
    );
    await tester.pump();
    expect(find.textContaining('Invalid'), findsNothing);
    expect(find.textContaining('格式'), findsNothing);
  });

  testWidgets('network advanced saves both fields with one button', (
    tester,
  ) async {
    final repository = FakeSettingsRepository(baseTestSettings());
    final router = createPixivRouter(initialLocation: '/settings/network');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
        ],
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('高级设置'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();

    // Page-level draft: a single Save commits whichever fields changed, and
    // stays disabled while nothing is dirty.
    final saveButton = find.widgetWithText(FilledButton, '保存');
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
    await tester.enterText(
      find.byType(TextField).at(0),
      'https://dns.alidns.com/dns-query',
    );
    await tester.enterText(find.byType(TextField).at(1), 'ech.example.com');
    await tester.pump();
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(
      repository.value.dohEndpointOverride,
      'https://dns.alidns.com/dns-query',
    );
    expect(repository.value.echFrontHost, 'ech.example.com');
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
  });

  testWidgets('network advanced reset asks before restoring defaults', (
    tester,
  ) async {
    final repository = FakeSettingsRepository(
      baseTestSettings().copyWith(
        dohEndpointOverride: 'https://9.9.9.9/dns-query',
        echFrontHost: 'custom-ech.example.com',
      ),
    );
    final router = createPixivRouter(initialLocation: '/settings/network');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
        ],
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('高级设置'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();

    // Reset rewrites two stored fields at once, so it asks first; cancelling
    // must not touch the stored values.
    await tester.scrollUntilVisible(
      find.text('恢复默认值'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认值'));
    await tester.pumpAndSettle();
    expect(find.text('将 DoH 端点与 ECH 前置主机恢复为默认值。'), findsOneWidget);
    final savedBefore = repository.saved.length;
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repository.saved, hasLength(savedBefore));

    await tester.tap(find.text('恢复默认值'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '恢复默认值'));
    await tester.pumpAndSettle();
    expect(repository.value.dohEndpointOverride, isNull);
    expect(repository.value.enableDoh, isTrue);
    expect(repository.value.echFrontHost, AppSettings.defaultEchFrontHost);
    expect(repository.saved.length, greaterThan(savedBefore));
  });

  testWidgets('network advanced dirty draft asks before leaving', (
    tester,
  ) async {
    final repository = FakeSettingsRepository(baseTestSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const NetworkAdvancedSettingsPage(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // A clean form pops straight through without a prompt.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(NetworkAdvancedSettingsPage), findsNothing);

    // A dirty draft asks; cancel keeps editing, discard leaves.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'https://dns.alidns.com/dns-query',
    );
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(NetworkAdvancedSettingsPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.byType(NetworkAdvancedSettingsPage), findsNothing);
  });

  testWidgets('network image source selects a preset and a custom proxy', (
    tester,
  ) async {
    final repository = FakeSettingsRepository(baseTestSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: NetworkSettingsPage(),
        ),
      ),
    );
    await tester.pump();
    // A tall surface builds every lazy row so ensureVisible-based
    // scrolling below stays legal.
    tester.view.physicalSize = const Size(800, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();

    expect(find.text('pixiv.cat 镜像'), findsOneWidget);
    expect(find.text('pixiv.re 镜像'), findsOneWidget);
    expect(find.text('pixiv.nl 镜像'), findsOneWidget);

    // The source section sits right after the network mode group.
    double dyOf(String text) => tester.getCenter(find.text(text)).dy;
    expect(dyOf('网络模式'), lessThan(dyOf('图片源')));

    await _scrollCentered(tester, find.text('pixiv.cat 镜像'));
    await tester.tap(find.text('pixiv.cat 镜像'));
    await tester.pumpAndSettle();
    expect(repository.value.imageSource, 'i.pixiv.cat');

    await _scrollCentered(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'proxy.example.com/pixiv/');
    await _scrollCentered(tester, find.text('保存', skipOffstage: false));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(
      repository.value.imageSource,
      'https://proxy.example.com/pixiv',
      reason: 'the bare host input is normalized to a canonical prefix',
    );
    expect(
      repository.value.customImageSource,
      'https://proxy.example.com/pixiv',
    );

    await _scrollCentered(
      tester,
      find.text('pixiv.re 镜像', skipOffstage: false),
    );
    await tester.tap(find.text('pixiv.re 镜像'));
    await tester.pumpAndSettle();
    expect(repository.value.imageSource, 'i.pixiv.re');

    // Reselecting the remembered custom value keeps the stored prefix.
    // widgetWithText avoids the TextField's label, which shares the string.
    await _scrollCentered(
      tester,
      find.widgetWithText(ListTile, '自定义反代', skipOffstage: false),
    );
    await tester.tap(find.widgetWithText(ListTile, '自定义反代'));
    await tester.pumpAndSettle();
    expect(repository.value.imageSource, 'https://proxy.example.com/pixiv');
  });

  testWidgets('network image source rejects an invalid custom input', (
    tester,
  ) async {
    final repository = FakeSettingsRepository(baseTestSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: NetworkSettingsPage(),
        ),
      ),
    );
    await tester.pump();
    // A tall surface builds every lazy row so ensureVisible-based
    // scrolling below stays legal.
    tester.view.physicalSize = const Size(800, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();

    await _scrollCentered(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'http://insecure.example');
    await _scrollCentered(tester, find.text('保存', skipOffstage: false));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repository.value.imageSource, AppSettings.normalImageSource);
    expect(find.textContaining('无效自定义源'), findsOneWidget);
  });

  testWidgets('browse page keeps only blocking and quality groups', (
    tester,
  ) async {
    final repository = FakeSettingsRepository(baseTestSettings());
    // Tall surface so every lazily-built row exists for position asserts.
    tester.view.physicalSize = const Size(800, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: BrowseSettingsPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    double dyOf(String text) => tester.getCenter(find.text(text)).dy;
    expect(dyOf('本地屏蔽 R-18 作品'), lessThan(dyOf('预览质量')));

    // Motion controls live on the motion page; the image source moved to
    // network settings — neither still renders here.
    expect(find.text('触感强度'), findsNothing);
    expect(find.text('页面转场'), findsNothing);
    expect(find.text('图片源'), findsNothing);

    // R4: pixivHistory has a single owner — the history settings page.
    expect(find.text('Pixiv 浏览历史'), findsNothing);
  });

  testWidgets('network custom input draft asks before leaving', (tester) async {
    final repository = FakeSettingsRepository(baseTestSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const NetworkSettingsPage(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A clean draft pops straight through without a prompt.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(NetworkSettingsPage), findsNothing);

    // Dirty draft: system back opens the discard dialog and 取消 stays.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(TextField),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byType(TextField), 'https://proxy.example.com');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(find.byType(NetworkSettingsPage), findsOneWidget);

    // 放弃 leaves the page and drops the draft.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.byType(NetworkSettingsPage), findsNothing);
  });

  testWidgets(
    'network image source apply-and-test applies then probes the live pipeline',
    (tester) async {
      final repository = FakeSettingsRepository(baseTestSettings());
      final backend = RecordingClient();
      final policy = NetworkAccessPolicy(
        registry: PixivDestinationRegistry(
          extraImageHosts: {'proxy.example.com'},
        ),
        resolver: StubResolver([InternetAddress('93.184.216.34')]),
        clientFactory: (route, canonicalHost, _) => backend,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(repository),
            networkAccessPolicyProvider.overrideWithValue(policy),
          ],
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: NetworkSettingsPage(),
          ),
        ),
      );
      await tester.pump();
      // A tall surface builds every lazy row so ensureVisible-based
      // scrolling below stays legal.
      tester.view.physicalSize = const Size(800, 4800);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pump();

      await _scrollCentered(tester, find.byType(TextField));
      await tester.enterText(
        find.byType(TextField),
        'https://proxy.example.com',
      );
      await _scrollCentered(tester, find.text('应用并测试', skipOffstage: false));
      await tester.tap(find.text('应用并测试'));
      await tester.pumpAndSettle();
      // The raced loser's drained body delivers its done event on the next
      // FakeAsync elapse — one more pump lets the idle-guard timer unwind.
      await tester.pump();

      // A cold image request races the top two ladder tiers, so the probe
      // may hit the backend twice — every attempt must target the mirror.
      expect(backend.requests, isNotEmpty);
      expect(backend.requests.map((request) => request.url.host).toSet(), {
        'proxy.example.com',
      });
      expect(repository.value.imageSource, 'https://proxy.example.com');
      expect(find.textContaining('镜像可达'), findsOneWidget);
    },
  );
  testWidgets('theme and language pages expose Semantics selected state', (
    tester,
  ) async {
    // R3: the check icon is the visual channel; Semantics(selected) is the
    // assistive one — both must move together.
    final repository = FakeSettingsRepository(baseTestSettings());
    Widget host(Widget home) => ProviderScope(
      overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: home,
      ),
    );

    await tester.pumpWidget(host(const ThemeSettingsPage()));
    await tester.pump();
    await tester.pump();
    expect(
      tester.getSemantics(find.widgetWithText(ListTile, '明亮')),
      isSemantics(isSelected: true),
    );
    expect(
      tester.getSemantics(find.widgetWithText(ListTile, '黑暗')),
      isSemantics(isSelected: false),
    );

    await tester.pumpWidget(host(const LanguageSettingsPage()));
    await tester.pump();
    await tester.pump();
    expect(
      tester.getSemantics(find.widgetWithText(ListTile, 'English')),
      isSemantics(isSelected: true),
    );
    expect(
      tester.getSemantics(find.widgetWithText(ListTile, '简体中文')),
      isSemantics(isSelected: false),
    );
  });

  testWidgets('choice pages mark the selected row with selected semantics', (
    tester,
  ) async {
    // R1: every single-choice row — not only theme and language — carries
    // the Semantics(selected) channel next to the check icon.
    final repository = FakeSettingsRepository(baseTestSettings());
    final translationStore = FakeTranslationStore();
    final policy = NetworkAccessPolicy(
      registry: PixivDestinationRegistry(),
      resolver: StubResolver([InternetAddress('93.184.216.34')]),
      clientFactory: (route, canonicalHost, _) => RecordingClient(),
    );
    Widget host(Widget home) => ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(repository),
        translationCredentialStoreProvider.overrideWithValue(translationStore),
        networkAccessPolicyProvider.overrideWithValue(policy),
      ],
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: home,
      ),
    );

    // Browse's image-source group sits at the bottom; a tall surface
    // builds every lazy row so the semantics checks below stay legal.
    tester.view.physicalSize = const Size(800, 4800);
    addTearDown(tester.view.resetPhysicalSize);

    Future<void> check(Widget page, String selected, String idle) async {
      await tester.pumpWidget(host(page));
      await tester.pump();
      await tester.pump();
      expect(
        tester.getSemantics(find.widgetWithText(ListTile, selected)),
        isSemantics(isSelected: true),
      );
      expect(
        tester.getSemantics(find.widgetWithText(ListTile, idle)),
        isSemantics(isSelected: false),
      );
    }

    await check(const TranslateSettingsPage(), '关闭', '百度翻译');
    await check(const DownloadSettingsPage(), '作品 ID（默认）', '标题 - ID');
    await check(const NetworkSettingsPage(), '自动', '仅直连');
    await check(const NetworkSettingsPage(), '官方源', 'pixiv.cat 镜像');
    await check(const DownloadDestinationPage(), '相册', '文件夹（系统目录选择）');

    // Unmount and unwind the third-party reachability probe timeouts.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
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

  group('haptic strength settings group', () {
    Future<FakeSettingsRepository> pumpPage(
      WidgetTester tester,
      RecordingHapticsDriver driver,
    ) async {
      final repository = FakeSettingsRepository(baseTestSettings());
      tester.view.physicalSize = const Size(800, 3200);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(repository),
            hapticsDriverProvider.overrideWithValue(driver),
          ],
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: MotionSettingsPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      // The group sits below the fold of a lazily-built list — scroll it
      // into the viewport first (finders cannot reach an unbuilt child).
      await tester.scrollUntilVisible(
        find.byType(SegmentedButton<HapticStrength>),
        300,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 20,
      );
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('picking a strength persists it and previews it', (
      tester,
    ) async {
      final driver = recordHaptics();
      final repository = await pumpPage(tester, driver);
      await tester.tap(find.text('强'));
      await tester.pumpAndSettle();
      expect(repository.value.hapticStrength, HapticStrength.strong);
      expect(repository.saved.last.hapticStrength, HapticStrength.strong);
      expect(driver.played, [(HapticRole.confirm, HapticStrength.strong)]);

      await tester.tap(find.text('关'));
      await tester.pumpAndSettle();
      expect(repository.value.hapticStrength, HapticStrength.off);
      // Off has nothing to preview.
      expect(driver.played, hasLength(1));
    });

    testWidgets('the footer names the device tier', (tester) async {
      const expected = {
        HapticsTier.composition: '本机支持精细振动，强度逐级可调',
        HapticsTier.predefined: '本机使用系统预设振动，强度按档位换用不同效果',
        HapticsTier.system: '本机仅支持系统触感，强度不可调',
        HapticsTier.none: '本机没有振动器',
      };
      for (final MapEntry(key: tier, value: text) in expected.entries) {
        final driver = RecordingHapticsDriver(
          capabilityResult: HapticsCapability(tier: tier, systemOff: false),
        );
        await pumpPage(tester, driver);
        expect(find.text(text), findsOneWidget, reason: '$tier');
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('the footer explains a system-wide haptics switch-off', (
      tester,
    ) async {
      final driver = RecordingHapticsDriver(
        capabilityResult: const HapticsCapability(
          tier: HapticsTier.composition,
          systemOff: true,
        ),
      );
      await pumpPage(tester, driver);
      expect(find.text('本机支持精细振动，强度逐级可调\n系统已关闭触摸振动，应用内触感不会生效'), findsOneWidget);
    });

    testWidgets('an unreadable capability says so', (tester) async {
      final driver = RecordingHapticsDriver()
        ..capabilityError = StateError('no channel');
      await pumpPage(tester, driver);
      expect(find.text('无法读取本机的振动能力'), findsOneWidget);
    });
  });
}

Future<void> _scrollCentered(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}

void _ignoreBool(bool value) {}

void _noop() {}
