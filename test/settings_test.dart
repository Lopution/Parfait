import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/haptics/haptics_driver.dart';
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
    show PixivNetworkFactory, PixivPolicyHttpClient;
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/history/history_repository.dart';
import 'package:parfait/features/illust/detail/illust_detail_pager_page.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/platform/account_transfer_clipboard.dart';
import 'package:parfait/features/settings/network_settings_page.dart';
import 'package:parfait/features/settings/saf_tree_name.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/features/settings/me_dashboard_page.dart';
import 'package:parfait/app/widgets/settings/settings_menu_tile.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:parfait/l10n/app_localizations_zh.dart';
import 'package:parfait/app/motion/removal.dart';

import 'helpers/connectivity_channels.dart';
import 'helpers/download_world.dart';
import 'helpers/history_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/image_network.dart';
import 'helpers/settings_world.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:go_router/go_router.dart';
import 'package:parfait/core/network/data_worker.dart';
import 'package:parfait/app/app.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';

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

/// The network settings page over [repository] and [overrides], on a tall
/// surface that builds every lazy row so ensureVisible-based scrolling
/// stays legal.
Future<void> _pumpNetworkSettings(
  WidgetTester tester,
  FakeSettingsRepository repository, {
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    localizedApp(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(repository),
        ...overrides,
      ],
      builder: promptHostBuilder,
      home: NetworkSettingsPage(),
    ),
  );
  await tester.pump();
  tester.view.physicalSize = const Size(800, 4800);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pump();
}

/// The account settings page signed in to account 42, exporting through
/// [clipboard].
Future<void> _pumpAccountSettings(
  WidgetTester tester,
  _TransferClipboard clipboard, {
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    localizedApp(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(
          FakeSettingsRepository(baseTestSettings()),
        ),
        ...accountProviderOverrides(
          metadataRepository: FakeAccountMetadataRepository.signedIn(
            const Account(id: '42', userId: 42, name: 'tester'),
          ),
          credentialStore: FakeCredentialStore(
            values: const {
              '42': Credential(accessToken: 'access', refreshToken: 'refresh'),
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
        ...overrides,
      ],
      builder: promptHostBuilder,
      home: AccountSettingsPage(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('settings read failures expose a retryable UI', (tester) async {
    final repository = FakeSettingsRepository(
      baseTestSettings(),
      failLoad: true,
    );
    await tester.pumpWidget(
      localizedApp(
        overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
        builder: promptHostBuilder,
        home: ThemeSettingsPage(),
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
        localizedApp(
          overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
          builder: promptHostBuilder,
          home: ThemeSettingsPage(),
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

  testWidgets(
    'account rows never show the email; the account page shows the ID',
    (tester) async {
      const account = Account(
        id: '42',
        userId: 42,
        name: 'tester',
        mailAddress: 'private@example.invalid',
      );
      for (final (page, showsId) in const [
        (MeDashboardPage(), false),
        (AccountSettingsPage(), true),
      ]) {
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
            child: localizedApp(builder: promptHostBuilder, home: page),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('账号 ID：42'),
          showsId ? findsOneWidget : findsNothing,
          reason: '$page',
        );
        expect(find.text('private@example.invalid'), findsNothing);
      }
    },
  );

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
        localizedApp(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(
              FakeSettingsRepository(baseTestSettings()),
            ),
            accountMetadataRepositoryProvider.overrideWithValue(repository),
            credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
          ],
          builder: promptHostBuilder,
          home: AccountSettingsPage(),
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
    setViewSize(tester, const Size(400, 1600));
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
      localizedApp(
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
        builder: promptHostBuilder,
        home: MeDashboardPage(),
      ),
    );
    await tester.pump();
    expect(
      find.text('帧探针'),
      findsOneWidget,
      reason: 'a build that can record lists the probe under the settings',
    );
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

  testWidgets('the recent row follows the history and pages in its own order', (
    tester,
  ) async {
    setViewSize(tester, const Size(400, 1600));
    answerConnectivityChannels();
    late HistoryRepository history;
    late ProviderContainer container;
    await tester.runAsync(() async {
      history = await openHistoryRepository(const []);
      container = await makeHistoryWorld(history);
    });
    final router = pixivRouter('/settings');
    await tester.pumpWidget(localizedRouterApp(router, container: container));
    // The row reads the ffi database, which answers on the real loop.
    Future<void> settle([Future<void> Function()? change]) =>
        tester.runAsync(() async {
          await change?.call();
          for (var i = 0; i < 2; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pump();
          }
        });
    Future<void> view(int id, int minute) => settle(
      () => history.upsert(
        historyRecord(
          id,
        ).copyWith(lastViewedAt: DateTime.utc(2026, 9, 20, 10, minute)),
      ),
    );
    Finder cover(int id) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == 'work $id',
      skipOffstage: false,
    );
    double x(int id) => tester.getTopLeft(cover(id)).dx;
    final viewAll = find.text('查看全部', skipOffstage: false);

    await settle();
    expect(viewAll, findsNothing, reason: 'no row without history');
    await view(1, 1);
    await view(2, 2);
    expect(viewAll, findsOneWidget);
    expect(x(2), lessThan(x(1)), reason: 'newest first');

    await tester.tap(cover(2));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final pager = tester.widget<IllustDetailPagerPage>(
      find.byType(IllustDetailPagerPage),
    );
    expect(pager.source.ids, [2, 1]);

    await view(1, 3);
    expect(pager.source.ids, [
      2,
      1,
    ], reason: 'the open pager keeps the order it was opened in');
    router.pop();
    await settle();
    await tester.pump(const Duration(seconds: 1));
    expect(x(1), lessThan(x(2)), reason: 'back on the page, the row re-read');

    await settle(() => history.clear('100'));
    expect(viewAll, findsNothing);
  });

  testWidgets('translation summary re-probes when the provider switches', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    final store = FakeTranslationStore()
      ..baidu = const BaiduTranslationCredentials(appId: 'id', secret: 'sec');
    await tester.pumpWidget(
      localizedApp(
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
        builder: promptHostBuilder,
        home: SettingsPage(),
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
      localizedApp(
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
        builder: promptHostBuilder,
        home: TranslateSettingsPage(),
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
        localizedApp(
          overrides: [settingsRepositoryProvider.overrideWithValue(repository)],
          builder: promptHostBuilder,
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
    final clipboard = _TransferClipboard();
    await _pumpAccountSettings(tester, clipboard);

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
      final clipboard = _TransferClipboard();
      await _pumpAccountSettings(
        tester,
        clipboard,
        overrides: [
          // Capability override: emulate an Android <13 device that
          // cannot mark the clipboard entry as sensitive.
          transferClipboardProvider.overrideWithValue(
            _TransferClipboard()..sensitiveMarkSupported = false,
          ),
        ],
      );

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
        find.text('此设备不支持敏感剪贴板标记（Android 13+ 才支持），凭据不会被标记为敏感内容。请尽快粘贴。'),
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
    final router = pixivRouter('/settings/network');
    await tester.pumpWidget(
      localizedRouterApp(
        router,
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
        ],
        builder: promptHostBuilder,
      ),
    );
    await tester.pumpAndSettle();

    // The mode tiles and status sections push this entry below the fold.
    await tester.scrollUntilVisible(
      find.text('高级设置'),
      400,
      scrollable: find
          .descendant(
            of: find.byType(NetworkSettingsPage),
            matching: find.byType(Scrollable),
          )
          .first,
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
    await _pumpNetworkSettings(tester, repository);

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
    await _pumpNetworkSettings(tester, repository);

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
      localizedApp(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(baseTestSettings()),
          ),
          networkAccessPolicyProvider.overrideWithValue(policy),
          imageWorkerProvider.overrideWithValue(worker),
        ],
        builder: promptHostBuilder,
        home: NetworkSettingsPage(),
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
    expect(find.textContaining('暂无路由记录'), findsNothing);

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
      await _pumpNetworkSettings(
        tester,
        repository,
        overrides: [networkAccessPolicyProvider.overrideWithValue(policy)],
      );

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

  group('haptic strength settings group', () {
    Future<FakeSettingsRepository> pumpPage(
      WidgetTester tester,
      RecordingHapticsDriver driver,
    ) async {
      final repository = FakeSettingsRepository(baseTestSettings());
      tester.view.physicalSize = const Size(800, 3200);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        localizedApp(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(repository),
            hapticsDriverProvider.overrideWithValue(driver),
          ],
          builder: promptHostBuilder,
          home: MotionSettingsPage(),
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

  group('settings change on a pushed page', () {
    testWidgets(
      'settings change on a pushed page must not jump to /recommended',
      (tester) async {
        SharedPreferencesAsyncPlatform.instance = memoryPreferences();
        setViewSize(tester, const Size(390, 844));
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('parfait/widget'),
          (call) async => false,
        );

        final container = ProviderContainer.test(
          overrides: [
            ...accountProviderOverrides(
              credentialStore: FakeCredentialStore(
                values: const {
                  '100': Credential(accessToken: 'a', refreshToken: 'r'),
                },
              ),
              metadataRepository: FakeAccountMetadataRepository.signedIn(
                const Account(id: '100', userId: 100, name: 't'),
              ),
            ),
            settingsRepositoryProvider.overrideWithValue(
              FakeSettingsRepository(
                AppSettings.defaults().copyWith(guideCompleted: true),
              ),
            ),
            // The app's isolate worker answers outside fake time.
            dataWorkerProvider.overrideWithValue(const InlineDataWorker()),
            pixivNetworkFactoryProvider.overrideWithValue(
              PixivNetworkFactory(
                NetworkAccessPolicy(
                  clientFactory: (route, host, purpose) =>
                      MockClient((_) async => http.Response('{}', 200)),
                ),
              ),
            ),
            downloadManagerProvider.overrideWithValue(
              DownloadManager(
                transport: FakeTransport(),
                sinkFactory: MemorySinkFactory(),
              ),
            ),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const ParfaitApp(),
          ),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        await tester.pumpAndSettle();

        final navEl = tester.element(find.byType(Navigator).first);
        final router = GoRouter.of(navEl);

        // Simulate the reported path: user is on /me (a declarative branch
        // switch — updates routeInformationProvider), then opens settings
        // (imperative push — does NOT update it). The gate must read the live
        // match, not the stale info-provider value.
        router.go('/me');
        await tester.pumpAndSettle();
        unawaited(router.push('/settings/theme'));
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/settings/theme');
        // The stale read the old code relied on:
        expect(
          router.routeInformationProvider.value.uri.path,
          isNot('/settings/theme'),
        );

        await container.read(settingsProvider.notifier).selectTheme(1);
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/settings/theme');
      },
    );
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
