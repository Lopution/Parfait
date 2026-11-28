import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/account_transfer.dart';
import 'package:parfait/core/auth/account_transfer_service.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/translation/translation_service.dart';
import 'package:parfait/core/translation/translation_credentials.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/network/compat/network_contracts.dart'
    show PixivDestinationPurpose, PixivDestinationRegistry;
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart'
    show PixivNetworkFactory, PixivPolicyHttpClient;
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/download/naming_rule.dart';
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
import 'package:parfait/l10n/app_localizations_zh.dart';
import 'package:parfait/app/motion/removal.dart';
import 'package:parfait/app/widgets/settings/settings_choice_tile.dart';

import 'helpers/download_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/image_network.dart';
import 'helpers/restricted_compat_support.dart' show FakeResolver;
import 'helpers/settings_world.dart';
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
import 'helpers/test_preferences.dart';
import 'helpers/waits.dart';
import 'package:parfait/app/icons/app_icons.dart';

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
  Future<VerifiedTransferAccount> verify(TransferAccountPayload payload) =>
      throw StateError('not used by export test');
  @override
  Future<VerifiedTransferAccount> verifyRefreshToken(String refreshToken) =>
      throw StateError('not used by export test');
}

/// The network settings page over the base settings and [overrides], on a
/// tall surface that builds every lazy row so ensureVisible-based scrolling
/// stays legal.
Future<void> _pumpNetworkSettings(
  WidgetTester tester, {
  List<Override> overrides = const [],
}) async {
  await seedSettings(baseTestSettings());
  await tester.pumpWidget(
    localizedApp(
      overrides: overrides,
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
  await seedAccounts([
    const Account(id: '42', userId: 42, name: 'tester'),
  ], currentId: '42');
  await seedSettings(baseTestSettings());
  await tester.pumpWidget(
    localizedApp(
      overrides: [
        ...accountProviderOverrides(
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
  testWidgets('settings read failures expose a retryable UI', (tester) async {
    installPreferencesForTest(
      GatedPreferences(keys: settingsKeys)
        ..readGate = (Future<void>.error(StateError('settings unavailable'))
          ..ignore()),
    );
    await tester.pumpWidget(
      localizedApp(
        overrides: const [],
        builder: promptHostBuilder,
        home: ThemeSettingsPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-load-error')), findsOneWidget);
    expect(find.byKey(const Key('settings-load-retry')), findsOneWidget);
  });

  testWidgets('account rows never show the email; each shows its own ID', (
    tester,
  ) async {
    const account = Account(
      id: '42',
      userId: 42,
      name: 'tester',
      mailAddress: 'private@example.invalid',
    );
    for (final (page, id) in const [
      (MeDashboardPage(), '用户 ID：42'),
      (AccountSettingsPage(), '账号 ID：42'),
    ]) {
      await seedAccounts(const [account], currentId: account.id);
      await seedSettings(baseTestSettings());
      await tester.pumpWidget(
        ProviderScope(
          // A fresh scope per page.
          key: ValueKey(page),
          overrides: [
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
      expect(find.text(id), findsOneWidget, reason: '$page');
      expect(find.text('private@example.invalid'), findsNothing);
    }
  });

  testWidgets(
    'account switch spins the target row and disables the list mid-commit',
    (tester) async {
      final preferences = GatedPreferences();
      installPreferencesForTest(preferences);
      await seedAccounts(const [
        Account(id: '1', userId: 1, name: 'first'),
        Account(id: '2', userId: 2, name: 'second'),
      ], currentId: '1');
      await seedSettings(baseTestSettings());
      // The metadata commit parks until the disk answers.
      final writing = Completer<void>();
      preferences.writeGate = writing.future;
      await tester.pumpWidget(
        localizedApp(
          overrides: [
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
              find.widgetWithIcon(IconButton, AppIcons.trash),
            )
            .map((button) => button.onPressed),
        everyElement(isNull),
      );

      writing.complete();
      await tester.pumpAndSettle();

      // After the commit the new current row carries the check and the
      // other row is tappable again.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect((await storedAccounts().load()).currentId, '2');
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
    final transport = FakeTransport()
      ..responses.add(
        ScriptedResponse(
          contentLength: 1,
          chunks: [
            [1],
          ],
          completers: [gate],
        ),
      );
    final manager = DownloadManager(
      transport: transport,
      sinkFactory: MemorySinkFactory(),
    );
    await seedSettings(baseTestSettings());
    await tester.pumpWidget(
      localizedApp(
        overrides: [
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
          downloadManagerProvider.overrideWithValue(manager),
        ],
        builder: promptHostBuilder,
        home: MeDashboardPage(),
      ),
    );
    await tester.pump();
    Badge downloadsBadge() => tester.widget<Badge>(
      find.descendant(
        of: find.widgetWithText(ListTile, '下载任务'),
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

    transport.responses.add(ScriptedResponse(error: Exception('disk full')));
    manager.submit(downloadRequest(2));
    await pumpUntil(tester, () => find.text('1 项失败').evaluate().isNotEmpty);
    expect(find.text('1 项失败'), findsOneWidget);
    await manager.dispose();
  });

  testWidgets('signed out, the Me header is one button to the login', (
    tester,
  ) async {
    final router = pixivRouter('/settings');
    await tester.pumpWidget(
      localizedRouterApp(
        router,
        overrides: [
          credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('账号管理'), findsNothing);
    // Pixiv keeps them with the account.
    expect(find.text('小说书签'), findsNothing);
    await tester.tap(find.text('未登录'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/login');
  });

  testWidgets('translation summary re-probes when the provider switches', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 4800);
    addTearDown(tester.view.resetPhysicalSize);
    final store = FakeTranslationStore()
      ..baidu = const BaiduTranslationCredentials(appId: 'id', secret: 'sec');
    await seedSettings(baseTestSettings().copyWith(translateIndex: 2));
    await tester.pumpWidget(
      localizedApp(
        overrides: [
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

  testWidgets(
    'download custom template disables save while invalid and guards drafts',
    (tester) async {
      await seedSettings(
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
          overrides: const [],
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

  testWidgets('export copies once after confirm; a clipboard that cannot '
      'mark it sensitive adds a warning', (tester) async {
    const warning = '此设备不支持敏感剪贴板标记（Android 13+ 才支持），凭据不会被标记为敏感内容。请尽快粘贴。';
    for (final sensitive in [true, false]) {
      final clipboard = _TransferClipboard()
        ..sensitiveMarkSupported = sensitive;
      await tester.pumpWidget(const SizedBox());
      await _pumpAccountSettings(
        tester,
        clipboard,
        overrides: [transferClipboardProvider.overrideWithValue(clipboard)],
      );

      await tester.tap(find.text('导出账号凭据'));
      await tester.pumpAndSettle();
      // The tile only opens the confirm dialog: nothing is exported yet.
      expect(clipboard.writeCount, 0);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(clipboard.writeCount, 1);
      expect(TransferEnvelope.parse(clipboard.text!), isA<TransferEnvelope>());

      // The warning queues behind the copied toast (4s); a security
      // downgrade is never silent (R4).
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        find.text(warning),
        sensitive ? findsNothing : findsOneWidget,
        reason: 'sensitive mark supported: $sensitive',
      );
    }
  });

  testWidgets('network advanced accepts hostname DoH endpoints', (
    tester,
  ) async {
    // Regression: the endpoint validator required IP-literal hosts, which
    // silently rejected the Cloudflare DoH domain defaults
    // (1dot1dot1dot1.cloudflare-dns.com) as soon as the user touched the
    // field. Domain endpoints are the production default now. DoH editing
    // lives on the advanced page (D3).
    await seedSettings(baseTestSettings());
    final router = pixivRouter('/settings/network');
    await tester.pumpWidget(
      localizedRouterApp(
        router,
        overrides: [
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
    await _pumpNetworkSettings(tester);

    expect(find.text('pixiv.nl 镜像'), findsOneWidget);

    // The source section sits right after the network mode group.
    double dyOf(String text) => tester.getCenter(find.text(text)).dy;
    expect(dyOf('网络模式'), lessThan(dyOf('图片源')));

    await _scrollCentered(tester, find.text('pixiv.cat 镜像'));
    await tester.tap(find.text('pixiv.cat 镜像'));
    await tester.pumpAndSettle();
    expect((await storedSettings().load()).imageSource, 'i.pixiv.cat');

    // An insecure custom input is refused; a bare host is normalized.
    await _scrollCentered(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'http://insecure.example');
    await _scrollCentered(tester, find.text('保存', skipOffstage: false));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect((await storedSettings().load()).imageSource, 'i.pixiv.cat');
    expect(find.textContaining('无效自定义源'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'proxy.example.com/pixiv/');
    await _scrollCentered(tester, find.text('保存', skipOffstage: false));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(
      (await storedSettings().load()).imageSource,
      'https://proxy.example.com/pixiv',
      reason: 'the bare host input is normalized to a canonical prefix',
    );
    expect(
      (await storedSettings().load()).customImageSource,
      'https://proxy.example.com/pixiv',
    );

    await _scrollCentered(
      tester,
      find.text('pixiv.re 镜像', skipOffstage: false),
    );
    await tester.tap(find.text('pixiv.re 镜像'));
    await tester.pumpAndSettle();
    expect((await storedSettings().load()).imageSource, 'i.pixiv.re');

    // Reselecting the remembered custom value keeps the stored prefix.
    // widgetWithText avoids the TextField's label, which shares the string.
    await _scrollCentered(
      tester,
      find.widgetWithText(ListTile, '自定义反代', skipOffstage: false),
    );
    await tester.tap(find.widgetWithText(ListTile, '自定义反代'));
    await tester.pumpAndSettle();
    expect(
      (await storedSettings().load()).imageSource,
      'https://proxy.example.com/pixiv',
    );
  });

  testWidgets('effective routes list the image worker\'s hosts and route '
      'candidates too', (tester) async {
    // Images load through the worker isolate's own policy: its routes are
    // a second answer, marked as image loading next to the main ones.
    final policy = stubNetworkPolicy();
    addTearDown(policy.dispose);
    final worker = await routedImageWorker(tester);
    await tester.runAsync(
      () => PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.appApi,
      ).get(Uri.parse('https://app-api.pixiv.net/v1/walkthrough')),
    );
    tester.view.physicalSize = const Size(800, 4800);
    addTearDown(tester.view.resetPhysicalSize);

    await seedSettings(baseTestSettings());
    await tester.pumpWidget(
      localizedApp(
        overrides: [
          networkAccessPolicyProvider.overrideWithValue(policy),
          imageWorkerProvider.overrideWithValue(worker),
        ],
        builder: promptHostBuilder,
        home: NetworkSettingsPage(),
      ),
    );
    await pumpIoUntil(
      tester,
      () => find.text('i.pixiv.re', skipOffstage: false).evaluate().isNotEmpty,
    );
    await _scrollCentered(tester, find.text('i.pixiv.re', skipOffstage: false));

    final apiRoute = find.widgetWithText(ListTile, 'app-api.pixiv.net');
    expect(apiRoute, findsOneWidget);
    expect(
      find.descendant(of: apiRoute, matching: find.text('图片加载')),
      findsNothing,
    );
    final imageRoute = find.widgetWithText(ListTile, 'i.pixiv.re');
    expect(
      find.descendant(of: imageRoute, matching: find.text('图片加载')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: imageRoute, matching: find.text('空 SNI')),
      findsOneWidget,
    );
    // The candidates go by number and colo, never by address.
    final front = find.widgetWithText(ListTile, 'Cloudflare 2 · HKG');
    expect(
      find.descendant(
        of: front,
        matching: find.text('图片加载 · 每 100 KB 约 0.8 秒 · 失败 10%'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: front, matching: find.text('使用中')),
      findsOneWidget,
    );
    final origin = find.widgetWithText(ListTile, 'Pixiv 源站');
    expect(
      find.descendant(of: origin, matching: find.text('使用中')),
      findsNothing,
    );
    expect(find.textContaining('暂无路由记录'), findsNothing);

    // Unmount and unwind the third-party reachability probe timeouts.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'network image source apply-and-test applies then probes the live pipeline',
    (tester) async {
      final backend = RecordingClient();
      final policy = NetworkAccessPolicy(
        registry: PixivDestinationRegistry(
          extraImageHosts: {'proxy.example.com'},
        ),
        resolver: FakeResolver([InternetAddress('93.184.216.34')]),
        clientFactory: (route, canonicalHost, _) => backend,
      );
      await _pumpNetworkSettings(
        tester,
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
      expect(
        (await storedSettings().load()).imageSource,
        'https://proxy.example.com',
      );
      expect(find.textContaining('镜像可达'), findsOneWidget);
    },
  );

  group('settings change on a pushed page', () {
    testWidgets(
      'settings change on a pushed page must not jump to /recommended',
      (tester) async {
        setViewSize(tester, const Size(390, 844));
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('parfait/widget'),
          (call) async => false,
        );

        await seedAccounts([
          const Account(id: '100', userId: 100, name: 't'),
        ], currentId: '100');
        await seedSettings(
          AppSettings.defaults().copyWith(guideCompleted: true),
        );
        final container = ProviderContainer.test(
          overrides: [
            ...accountProviderOverrides(
              credentialStore: FakeCredentialStore(
                values: const {
                  '100': Credential(accessToken: 'a', refreshToken: 'r'),
                },
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

    testWidgets(
      'SettingsChoiceTile exposes ListTile.selected semantics to screen readers',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            localizedApp(
              body: Column(
                children: [
                  SettingsChoiceTile(
                    title: const Text('Light'),
                    selected: true,
                    onTap: () {},
                  ),
                  SettingsChoiceTile(
                    title: const Text('Dark'),
                    selected: false,
                    onTap: () {},
                  ),
                ],
              ),
            ),
          );
          expect(
            tester.getSemantics(find.text('Light')),
            isSemantics(label: 'Light', isSelected: true),
          );
          expect(
            tester.getSemantics(find.text('Dark')),
            isSemantics(label: 'Dark', isSelected: false),
          );
        } finally {
          semantics.dispose();
        }
      },
    );
  });
}

Future<void> _scrollCentered(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}
