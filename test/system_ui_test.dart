import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:parfait/core/network/data_worker.dart';
import 'package:parfait/app/app.dart';
import 'package:parfait/app/system_ui.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart';
import 'package:parfait/core/navigation/route_observer.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:parfait/features/novel/novel_layout.dart';
import 'package:parfait/features/novel/novel_reader_stage.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/image_network.dart';
import 'helpers/download_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/fake_settings.dart';
import 'helpers/localized_app.dart';
import 'helpers/test_preferences.dart';

List<String> _recordSystemUiModes() {
  final modes = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
      modes.add(call.arguments as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return modes;
}

void main() {
  test('a platform failure is logged, not thrown or dropped', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
        throw PlatformException(code: 'unavailable', message: 'no engine');
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final printed = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) printed.add(message);
    };
    try {
      // Completes normally — desktop embedders and detached engines must not
      // crash the caller — but the failure leaves a log line.
      await setSystemUiMode(SystemUiMode.edgeToEdge);
    } finally {
      debugPrint = previousDebugPrint;
    }
    expect(printed, anyElement(contains('setEnabledSystemUIMode')));
  });

  testWidgets('the viewer hides to immersiveSticky and exits to edgeToEdge', (
    tester,
  ) async {
    debugResetViewerSession();
    addTearDown(debugResetViewerSession);
    final modes = _recordSystemUiModes();

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      withStalledImages(
        localizedApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const ImageViewerPage(urls: ['https://i.pximg.net/1/original.jpg']),
      ),
    );
    await tester.pumpAndSettle();

    // Chrome starts visible; a lone tap hides it → immersiveSticky. The
    // tap resolves after the double-tap window (~300ms).
    await tester.tap(find.byType(PageView));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(modes, contains('SystemUiMode.immersiveSticky'));

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(
      modes.last,
      'SystemUiMode.edgeToEdge',
      reason: 'leaving the viewer always restores the ambient edge-to-edge',
    );
  });

  testWidgets('startup enters edgeToEdge once (D2)', (tester) async {
    final modes = _recordSystemUiModes();
    await _pumpApp(
      tester,
      AppSettings.defaults().copyWith(guideCompleted: true),
    );

    expect(
      modes.where((mode) => mode == 'SystemUiMode.edgeToEdge'),
      hasLength(1),
      reason: 'edge-to-edge is an app-start contract, not a per-page side',
    );
  });

  testWidgets(
    'novel reader restores edgeToEdge when covered and re-enters immersiveSticky on pop',
    (tester) async {
      debugResetViewerSession();
      addTearDown(debugResetViewerSession);
      installPreferencesForTest(memoryPreferences());
      final modes = _recordSystemUiModes();

      final observer = ExitAwareRouteObserver();
      final nav = GlobalKey<NavigatorState>();
      final novel = NovelEntity(
        id: 77,
        title: 'Immersive novel',
        caption: '',
        user: const UserEntity(id: 1, name: 'a', account: 'a'),
        tags: const [],
        textLength: 40,
        contentVersion: 'v1',
        paragraphs: NovelContentMapper.fromText('body line'),
        contentAvailable: true,
      );
      await tester.pumpWidget(
        withStalledImages(
          ProviderScope(
            child: RouteObserverScope(
              observer: observer,
              child: MaterialApp(
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                navigatorKey: nav,
                navigatorObservers: [observer],
                home: Scaffold(
                  body: NovelReaderStage(
                    spec: NovelReaderStageSpec(
                      novel: novel,
                      infoTooltip: 'info',
                      infoSheet: (_) => const SizedBox.shrink(),
                      progress: const _NoopReaderProgressBinding(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(modes.last, 'SystemUiMode.immersiveSticky');

      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      expect(modes.last, 'SystemUiMode.edgeToEdge');

      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(modes.last, 'SystemUiMode.immersiveSticky');

      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const ImageViewerPage(
            urls: ['https://i.pximg.net/1/original.jpg'],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PageView));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(modes.last, 'SystemUiMode.immersiveSticky');
    },
  );
}

class _NoopReaderProgressBinding implements ReaderProgressBinding {
  const _NoopReaderProgressBinding();

  @override
  Future<NovelAnchor?> load() async => null;

  @override
  Future<void> save(NovelAnchor anchor) async {}
}

/// Pumps the whole app signed in with [settings] and lets startup settle,
/// including the delayed auto-update check.
Future<void> _pumpApp(WidgetTester tester, AppSettings settings) async {
  // Widget coordinator gate — keeps startup quiet without a native side.
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('parfait/widget'),
    (call) async => false,
  );

  await seedAccounts([
    const Account(id: '100', userId: 100, name: 't'),
  ], currentId: '100');
  await seedSettings(settings);
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
    UncontrolledProviderScope(container: container, child: const ParfaitApp()),
  );
  // The delayed auto-update check (3s) must fire before the test ends —
  // pump past it like the other app-level tests do.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
  await tester.pumpAndSettle();
}
