import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/account_transfer.dart';
import 'package:parfait/core/auth/account_transfer_service.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/translation/translation_service.dart';
import 'package:parfait/core/translation/translation_credentials.dart';
import 'package:parfait/features/settings/pages/doubao_login_page.dart';
import 'package:parfait/core/image/image_worker.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/network/compat/network_contracts.dart'
    show PixivDestinationPurpose, PixivDestinationRegistry;
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart'
    show PixivPolicyHttpClient;
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/reverse_image/reverse_image_engine.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/settings/settings_repository.dart';
import 'package:parfait/core/platform/account_transfer_clipboard.dart';
import 'package:parfait/features/settings/network_settings_page.dart';
import 'package:parfait/features/settings/saf_tree_name.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/features/settings/me_dashboard_page.dart';
import 'package:parfait/app/widgets/settings/settings_menu_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_zh.dart';
import 'package:parfait/app/motion/removal.dart';

import 'helpers/download_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/image_network.dart';
import 'helpers/settings_world.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';

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

  test('setSearchFilters persists each type set independently', () async {
    final repository = FakeSettingsRepository(baseTestSettings());
    final container = ProviderContainer(
      overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
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
      'pageTransitionStyle': 'zoom',
    }, fallback: baseTestSettings());
    expect(unknown.pageTransitionStyle, PageTransitionStyle.system);
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

  testWidgets('settings read failures expose a retryable UI', (tester) async {
    final repository = FakeSettingsRepository(
      baseTestSettings(),
      failLoad: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          builder: promptHostBuilder,
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

  group('follow system colors', () {
    /// The platform answers through the dynamic_color channel (external
    /// boundary): no Android palette, and [accent] for the accent query.
    void mockAccent(Future<int?> Function() accent) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        DynamicColorPlugin.channel,
        (call) => call.method == DynamicColorPlugin.accentColorMethodName
            ? accent()
            : Future.value(),
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          DynamicColorPlugin.channel,
          null,
        ),
      );
    }

    Future<FakeSettingsRepository> pumpThemePage(WidgetTester tester) async {
      final repository = FakeSettingsRepository(baseTestSettings());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
          child: const MaterialApp(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: ThemeSettingsPage(),
          ),
        ),
      );
      return repository;
    }

    SwitchListTile followSwitch(WidgetTester tester) => tester
        .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '跟随系统取色'));

    testWidgets('a system palette enables the switch and it persists', (
      tester,
    ) async {
      mockAccent(() async => 0xFF3366CC);
      final repository = await pumpThemePage(tester);
      await tester.pumpAndSettle();

      expect(find.text('用壁纸或系统强调色作为主题色'), findsOneWidget);
      expect(followSwitch(tester).value, isFalse);
      await tester.tap(find.text('跟随系统取色'));
      await tester.pumpAndSettle();

      expect(repository.value.followSystemColors, isTrue);
      expect(followSwitch(tester).value, isTrue);
    });
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
    for (final page in const [MeDashboardPage(), AccountSettingsPage()]) {
      await tester.pumpWidget(
        ProviderScope(
          // A fresh scope per page.
          key: ValueKey(page),
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
            credentialStoreProvider.overrideWithValue(
              FakeCredentialStore(
                values: const {
                  '42': Credential(accessToken: 'a', refreshToken: 'r'),
                },
              ),
            ),
          ],
          child: MaterialApp(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('账号 ID：42'), findsOneWidget, reason: '$page');
      expect(find.text('private@example.invalid'), findsNothing);
    }
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
            builder: promptHostBuilder,
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

  testWidgets('the dashboard badge counts downloads as they start and end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gate = Completer<void>();
    final manager = DownloadManager(
      transport: FakeTransport()
        ..responses.add(
          ScriptedResponse(
            contentLength: 1,
            chunks: [
              [1],
            ],
            completers: [gate],
          ),
        ),
      sinkFactory: MemorySinkFactory(),
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
          downloadManagerProvider.overrideWithValue(manager),
        ],
        child: const MaterialApp(
          builder: promptHostBuilder,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: MeDashboardPage(),
        ),
      ),
    );
    await tester.pump();
    Badge downloadsBadge() => tester.widget<Badge>(
      find.ancestor(
        of: find.byIcon(Icons.downloading_outlined),
        matching: find.byType(Badge),
      ),
    );
    expect(downloadsBadge().isLabelVisible, isFalse);

    manager.submit(downloadRequest(1));
    await pumpUntil(tester, () => downloadsBadge().isLabelVisible);
    expect(downloadsBadge().isLabelVisible, isTrue);
    expect(
      find.descendant(
        of: find.byWidget(downloadsBadge()),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );

    gate.complete();
    await pumpUntil(tester, () => !downloadsBadge().isLabelVisible);
    expect(downloadsBadge().isLabelVisible, isFalse);
    await manager.dispose();
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
          builder: promptHostBuilder,
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

  testWidgets('signing out of Doubao clears the session and its cookies', (
    tester,
  ) async {
    final store = FakeTranslationStore()
      ..doubao = const DoubaoWebSession(cookie: 'sessionid=a', teaUuid: '1');
    final cookies = _FakeDoubaoCookies();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(
              baseTestSettings().copyWith(
                translateIndex: TranslationProvider.doubao.code,
              ),
            ),
          ),
          translationCredentialStoreProvider.overrideWithValue(store),
          doubaoWebCookiesProvider.overrideWithValue(cookies),
        ],
        child: const MaterialApp(
          builder: promptHostBuilder,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: TranslateSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('已登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '退出登录'));
    await tester.pumpAndSettle();

    expect(store.doubao, isNull);
    expect(cookies.cleared, 1);
    expect(find.text('未登录'), findsOneWidget);
  });

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
            builder: promptHostBuilder,
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
          builder: promptHostBuilder,
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
            builder: promptHostBuilder,
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
          builder: promptHostBuilder,
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

  testWidgets('network image source selects a preset and a custom proxy', (
    tester,
  ) async {
    final repository = FakeSettingsRepository(baseTestSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          builder: promptHostBuilder,
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
          builder: promptHostBuilder,
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

  testWidgets('effective routes list the image worker\'s hosts too', (
    tester,
  ) async {
    // Images load through the worker isolate's own policy: its routes are
    // a second answer, marked as image loading next to the main ones.
    final policy = stubNetworkPolicy();
    addTearDown(policy.dispose);
    final worker = ImageWorker(
      start: (_, demand) =>
          scriptedImageWorkerClient(demand, routes: {'i.pximg.net': 'ech'}),
      config: () async => testImageWorkerConfig,
    );
    await tester.runAsync(() async {
      await PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.appApi,
      ).get(Uri.parse('https://app-api.pixiv.net/v1/walkthrough'));
      // Only a running worker is asked; the page never starts one.
      await worker.cachedFile('https://i.pximg.net/img-master/a.jpg');
    });
    addTearDown(() => tester.runAsync(worker.dispose));
    tester.view.physicalSize = const Size(800, 4800);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(baseTestSettings()),
          ),
          networkAccessPolicyProvider.overrideWithValue(policy),
          imageWorkerProvider.overrideWithValue(worker),
        ],
        child: const MaterialApp(
          builder: promptHostBuilder,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: NetworkSettingsPage(),
        ),
      ),
    );
    await pumpIoUntil(
      tester,
      () => find.text('i.pximg.net', skipOffstage: false).evaluate().isNotEmpty,
    );
    await _scrollCentered(
      tester,
      find.text('i.pximg.net', skipOffstage: false),
    );

    final apiRoute = find.widgetWithText(ListTile, 'app-api.pixiv.net');
    expect(apiRoute, findsOneWidget);
    expect(
      find.descendant(of: apiRoute, matching: find.text('图片加载')),
      findsNothing,
    );
    final imageRoute = find.widgetWithText(ListTile, 'i.pximg.net');
    expect(
      find.descendant(of: imageRoute, matching: find.text('图片加载')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: imageRoute, matching: find.text('ECH')),
      findsOneWidget,
    );
    expect(find.textContaining('还没有路由记录'), findsNothing);

    // Unmount and unwind the third-party reachability probe timeouts.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
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
            builder: promptHostBuilder,
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
            builder: promptHostBuilder,
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
        find.byType(SettingsMenuTile<HapticStrength>),
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
      Future<void> pick(String label) async {
        await tester.tap(find.byType(SettingsMenuTile<HapticStrength>));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(MenuItemButton),
            matching: find.text(label),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pick('强');
      expect(repository.value.hapticStrength, HapticStrength.strong);
      expect(repository.saved.last.hapticStrength, HapticStrength.strong);
      expect(driver.played, [(HapticRole.confirm, HapticStrength.strong)]);

      await pick('关');
      expect(repository.value.hapticStrength, HapticStrength.off);
      // Off has nothing to preview.
      expect(driver.played, hasLength(1));
    });
  });
}

Future<void> _scrollCentered(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}

class _FakeDoubaoCookies implements DoubaoWebCookies {
  var cleared = 0;

  @override
  Future<String?> sessionCookie() async => null;

  @override
  Future<void> clear() async => cleared++;
}
