import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/account_transfer.dart';
import 'package:pixiv_func/core/auth/account_transfer_service.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/i18n/replica_strings.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';
import 'package:pixiv_func/core/settings/settings_controller.dart';
import 'package:pixiv_func/core/settings/settings_repository.dart';
import 'package:pixiv_func/core/platform/account_transfer_clipboard.dart';
import 'package:pixiv_func/features/settings/network_settings_page.dart';
import 'package:pixiv_func/features/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _FakeRepository implements SettingsRepository {
  _FakeRepository(this.value);

  AppSettings value;
  bool failWrites = false;
  final saved = <AppSettings>[];
  Duration writeDelay = Duration.zero;

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async {
    if (writeDelay != Duration.zero) await Future<void>.delayed(writeDelay);
    if (failWrites) throw StateError('settings disk full');
    value = settings;
    saved.add(settings);
  }
}

class _CredentialStore implements CredentialStore {
  @override
  Future<Credential?> read(String accountId) async =>
      const Credential(accessToken: 'access', refreshToken: 'refresh');

  @override
  Future<void> write(String accountId, Credential credential) async {}

  @override
  Future<void> delete(String accountId) async {}
}

class _AccountRepository implements AccountMetadataRepository {
  _AccountRepository([this.initial = const []]);

  final List<Account> initial;

  @override
  Future<AccountMetadataSnapshot> load() async =>
      AccountMetadataSnapshot(
        accounts: initial,
        currentId: initial.isEmpty ? null : initial.first.id,
      );

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
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
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('defaults use safe modern values and beta56 setting names', () {
    final settings = AppSettings.defaults();
    expect(settings.guideCompleted, isFalse);
    expect(settings.themeCode, AppSettings.systemTheme);
    expect(settings.imageSource, AppSettings.normalImageSource);
    expect(settings.previewQuality, isTrue);
    expect(settings.scaleQuality, isTrue);
    expect(settings.enableHistory, isTrue);
    expect(settings.enablePixivHistory, isTrue);
    expect(settings.enableLocalBlockR18, isFalse);
    expect(settings.enableLocalBlockAI, isFalse);
    expect(settings.translateIndex, 0);
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
    expect(settings.previewQuality, isFalse);
    expect(settings.scaleQuality, isTrue);
    expect(settings.enableHistory, isFalse);
    expect(settings.maxDownloadCount, 3);
    expect(settings.namingRule, 'artist_{id}');
    expect(settings.translateIndex, 0);
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
    expect(
      jsonDecode(
        (await preferences.getString(
          PreferencesSettingsRepository.settingsKey,
        ))!,
      )['schemaVersion'],
      AppSettings.currentSchemaVersion,
    );
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
    expect(settings.translateIndex, 0);
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
        controller.setPreviewQuality(false),
        throwsA(isA<SettingsWriteException>()),
      );
      expect(
        container.read(settingsProvider).requireValue.previewQuality,
        isTrue,
      );
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
      'scaleQuality',
      'localHistory',
      'pixivHistory',
      'blockR18',
      'blockAI',
      'maxDownloadCount',
      'namingRule',
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
    for (final language in ReplicaLanguage.values) {
      for (final key in keys) {
        expect(
          ReplicaStrings.text(language, key),
          isNotEmpty,
          reason: '$language/$key',
        );
      }
    }
  });

  testWidgets('settings home shows the beta56 route order', (tester) async {
    final repository = _FakeRepository(_baseSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          accountMetadataRepositoryProvider.overrideWithValue(
            _AccountRepository(),
          ),
          credentialStoreProvider.overrideWithValue(_CredentialStore()),
        ],
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
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

  testWidgets('long-pressing an account card exports bounded transfer data',
      (tester) async {
    final repository = _AccountRepository([
      const Account(id: '42', userId: 42, name: 'tester'),
    ]);
    final clipboard = _TransferClipboard();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(_FakeRepository(_baseSettings())),
          accountMetadataRepositoryProvider.overrideWithValue(repository),
          credentialStoreProvider.overrideWithValue(_CredentialStore()),
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
          locale: Locale('zh', 'CN'),
          supportedLocales: [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('tester'));
    await tester.pumpAndSettle();

    expect(clipboard.writeCount, 1);
    expect(
      TransferEnvelope.parse(clipboard.text!),
      isA<TransferEnvelope>(),
    );
  });

  testWidgets(
      'exporting on a device without sensitive clipboard shows a warning',
      (tester) async {
        final repository = _AccountRepository([
          const Account(id: '42', userId: 42, name: 'tester'),
        ]);
        final clipboard = _TransferClipboard();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsRepositoryProvider.overrideWithValue(
                _FakeRepository(_baseSettings()),
              ),
              accountMetadataRepositoryProvider.overrideWithValue(repository),
              credentialStoreProvider.overrideWithValue(_CredentialStore()),
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
                _TransferClipboard()
                  ..sensitiveMarkSupported = false,
              ),
            ],
            child: const MaterialApp(
              locale: Locale('zh', 'CN'),
              supportedLocales: [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
          find.text('此设备不支持敏感剪贴板标记（Android 13+ 才支持）：凭据将以明文进入系统剪贴板，请尽快粘贴；5 分钟后自动清除。'),
          findsOneWidget,
        );
      });

  testWidgets('network settings accepts hostname DoH endpoints',
      (tester) async {
    // Regression: the endpoint validator required IP-literal hosts, which
    // silently rejected the Cloudflare DoH domain defaults
    // (1dot1dot1dot1.cloudflare-dns.com) as soon as the user touched the
    // field. Domain endpoints are the production default now.
    final repository = _FakeRepository(_baseSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          accountMetadataRepositoryProvider.overrideWithValue(
            _AccountRepository(),
          ),
          credentialStoreProvider.overrideWithValue(_CredentialStore()),
        ],
        child: const MaterialApp(
          locale: Locale('zh', 'CN'),
          supportedLocales: [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: NetworkSettingsPage(),
        ),
      ),
    );
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
