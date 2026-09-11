import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/account_transfer.dart';
import 'package:pixiv_func/core/auth/account_transfer_service.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/download/naming_rule.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';
import 'package:pixiv_func/core/settings/settings_controller.dart';
import 'package:pixiv_func/core/settings/settings_repository.dart';
import 'package:pixiv_func/core/platform/account_transfer_clipboard.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/core/user/user_repository.dart';
import 'package:pixiv_func/features/settings/settings_page.dart';
import 'package:pixiv_func/features/profile/user_page.dart' as profile;
import 'package:pixiv_func/app/widgets/settings/settings_control.dart';
import 'package:pixiv_func/app/widgets/settings/settings_section.dart';
import 'package:pixiv_func/app/widgets/settings/settings_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/lookup.dart';
import 'package:pixiv_func/l10n/app_localizations_zh.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

class _FakeRepository implements SettingsRepository {
  _FakeRepository(this.value, {this.failLoad = false});

  AppSettings value;
  bool failLoad;
  bool failWrites = false;
  final saved = <AppSettings>[];
  Duration writeDelay = Duration.zero;

  @override
  Future<AppSettings> load() async {
    if (failLoad) throw StateError('settings unavailable');
    return value;
  }

  @override
  Future<void> save(AppSettings settings) async {
    if (writeDelay != Duration.zero) await Future<void>.delayed(writeDelay);
    if (failWrites) throw StateError('settings disk full');
    value = settings;
    saved.add(settings);
  }
}

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

AppSettings _baseSettings() => const AppSettings(
  guideCompleted: true,
  languageTag: 'en-US',
  themeCode: AppSettings.lightTheme,
  imageSource: AppSettings.normalImageSource,
);

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test('defaults use safe modern values and beta56 setting names', () {
    final settings = AppSettings.defaults();
    expect(settings.guideCompleted, isFalse);
    expect(settings.themeCode, AppSettings.systemTheme);
    expect(settings.imageSource, AppSettings.normalImageSource);
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
    }, fallback: _baseSettings());

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
      final repository = _FakeRepository(_baseSettings())
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

  test('networkModeCode round-trips and missing key defaults to automatic', () {
    final stored = _baseSettings().copyWith(
      networkMode: NetworkMode.directOnly,
    );
    final encoded = stored.toJson();
    expect(encoded['networkModeCode'], NetworkMode.directOnly.code);
    final restored = AppSettings.fromJson(encoded, fallback: _baseSettings());
    expect(restored.networkMode, NetworkMode.directOnly);

    final missing = AppSettings.fromJson({
      'guideCompleted': true,
      'languageTag': 'en-US',
      'themeCode': AppSettings.lightTheme,
    }, fallback: _baseSettings());
    expect(missing.networkMode, NetworkMode.automatic);
  });

  test('legacy previewQuality true migrates to PreviewQuality.large', () {
    final settings = AppSettings.fromJson({
      'previewQuality': true,
    }, fallback: _baseSettings());
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
      }, fallback: _baseSettings());
      expect(fromFalse.viewQuality, ViewQuality.large);

      final fromTrue = AppSettings.fromJson({
        'scaleQuality': true,
      }, fallback: _baseSettings());
      expect(fromTrue.viewQuality, ViewQuality.original);
    },
  );

  test('plain settings JSON never contains translation credentials', () {
    final json = _baseSettings().toJson();
    expect(json.keys, isNot(contains('translateAuthData')));
    expect(json.values, isNot(contains('access-token')));
    expect(AppSettings.translationCredentialRef.credentialKey, isNotEmpty);
  });

  test('all settings labels are available in all supported languages', () {
    const keys = [
      'settingsTitle',
      'accountSettings',
      'networkSettings',
      'networkMode',
      'networkModeHint',
      'networkModeListTitle',
      'networkModeAutomatic',
      'networkModeAutomaticHint',
      'networkModeDirectOnly',
      'networkModeDirectOnlyHint',
      'networkAdvanced',
      'networkAdvancedHint',
      'networkAdvancedReset',
      'networkDoh',
      'networkDohHint',
      'networkDohEndpoints',
      'networkProbe',
      'networkProbeHint',
      'networkProbeRun',
      'networkProbeRunning',
      'networkProbeNotRun',
      'networkProbeCopied',
      'themeSettings',
      'languageSettings',
      'translateSettings',
      'browseSettings',
      'downloadSettings',
      'historySettings',
      'blockTagSettings',
      'downloaderSettings',
      'aboutSettings',
      'imageSourceNormal',
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
      'saveLocationUseCustomAlbum',
      'saveLocationAlbumInvalid',
      'saveLocationSafFolder',
      'saveLocationSafFolderHint',
      'saveLocationSafPicked',
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
    final repository = _FakeRepository(_baseSettings());
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
    final selectorFinder = find.byWidgetPredicate(
      (widget) => widget is SegmentedButton<dynamic>,
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

    await tester.tap(
      find.descendant(of: selectorFinder.at(0), matching: find.text('大图')),
    );
    await tester.pumpAndSettle();
    expect(repository.value.previewQuality, PreviewQuality.large);

    await tester.tap(
      find.descendant(of: selectorFinder.at(1), matching: find.text('原图')),
    );
    await tester.pumpAndSettle();
    expect(repository.value.detailQuality, DetailQuality.original);
  });

  testWidgets('settings primitives expose headings, values and actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SettingsSection(title: Text('Display')),
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
    final repository = _FakeRepository(_baseSettings(), failLoad: true);
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
            _FakeRepository(_baseSettings()),
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

  testWidgets('settings home shows the beta56 route order', (tester) async {
    final repository = _FakeRepository(_baseSettings());
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
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('浏览设置'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pump();
    expect(find.text('下载任务'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('新作'), findsNothing);
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
            _FakeRepository(_baseSettings()),
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

    await tester.tap(find.text('tester'));
    await tester.pumpAndSettle();

    expect(find.byType(profile.MePage), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
  });

  testWidgets('long-pressing an account card exports bounded transfer data', (
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
            _FakeRepository(_baseSettings()),
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

          home: SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('tester'));
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
              _FakeRepository(_baseSettings()),
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

            home: SettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.text('tester'));
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
    final repository = _FakeRepository(_baseSettings());
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
}

void _ignoreBool(bool value) {}

void _noop() {}
