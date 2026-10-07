import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:parfait/app/app.dart';
import 'package:parfait/app/system_ui.dart';
import 'package:parfait/app/theme/func_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/settings/settings_repository.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/image_network.dart';
import 'helpers/download_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

/// Mounts the root system-bar default exactly like app.dart's builder: the
/// outermost widget inside the theme, reading the resolved brightness.
Widget _app({
  required ThemeData theme,
  GlobalKey<NavigatorState>? navigatorKey,
  Widget? home,
}) {
  return MaterialApp(
    navigatorKey: navigatorKey,
    theme: theme,
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh', 'CN'),
    builder: (context, routeChild) => FuncSystemBars(
      background: Theme.of(context).brightness,
      child: routeChild ?? const SizedBox.shrink(),
    ),
    home: home ?? const Scaffold(body: SizedBox.expand()),
  );
}

void main() {
  testWidgets('a page with no AppBar keeps bar icons inverted to the theme', (
    tester,
  ) async {
    // Control first: a bare MaterialApp publishes the framework default —
    // light nav-bar icons over an opaque black bar. Without the root
    // FuncSystemBars wrap (the app.dart wiring this harness mirrors) the
    // assertions below degenerate to exactly this, so the contrast makes
    // the test non-vacuous.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    await tester.pump();
    await tester.pump();
    expect(
      SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
      Brightness.light,
    );
    expect(
      SystemChrome.latestStyle?.systemNavigationBarColor,
      const Color(0xFF000000),
    );

    // RenderView applies the AnnotatedRegion during compositing and
    // latestStyle updates in the following microtask — pump twice before
    // reading so the write lands.
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(_app(theme: replicaTheme(brightness)));
      // AnimatedTheme lerps on the second iteration — let it land before
      // reading the brightness-driven style.
      await tester.pumpAndSettle();
      await tester.pump();

      final style = SystemChrome.latestStyle;
      final icons = brightness == Brightness.light
          ? Brightness.dark
          : Brightness.light;
      expect(
        style?.statusBarIconBrightness,
        icons,
        reason: '$brightness theme must paint $icons status-bar icons',
      );
      expect(
        style?.systemNavigationBarIconBrightness,
        icons,
        reason: '$brightness theme must paint $icons nav-bar icons',
      );
      // Both bars stay transparent — the framework default paints an
      // opaque black navigation bar.
      expect(style?.statusBarColor, const Color(0x00000000));
      expect(style?.systemNavigationBarColor, const Color(0x00000000));
    }
  });

  testWidgets('a scoped FuncSystemBars overrides the root and restores', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      _app(theme: replicaTheme(Brightness.light), navigatorKey: navigatorKey),
    );
    await tester.pump();
    await tester.pump();
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.dark);

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const FuncSystemBars(
          background: Brightness.dark,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump();
    expect(
      SystemChrome.latestStyle?.statusBarIconBrightness,
      Brightness.light,
      reason: 'the black page must paint light icons while it is mounted',
    );
    expect(
      SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
      Brightness.light,
    );

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pump();
    expect(
      SystemChrome.latestStyle?.statusBarIconBrightness,
      Brightness.dark,
      reason: 'leaving the page restores the root style — no imperative reset',
    );
  });

  testWidgets('the image viewer pins light bar icons while mounted', (
    tester,
  ) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        withStalledImages(
          MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            theme: replicaTheme(Brightness.light),
            home: const ImageViewerPage(
              urls: ['https://i.pximg.net/1/original.jpg'],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    });

    // The black stage overrides the light theme's dark icons; without the
    // override the clock is invisible after immersive mode exits.
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.light);
    expect(
      SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
      Brightness.light,
    );
  });

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

    final navigatorKey = GlobalKey<NavigatorState>();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        withStalledImages(
          MaterialApp(
            navigatorKey: navigatorKey,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const ImageViewerPage(
            urls: ['https://i.pximg.net/1/original.jpg'],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Chrome starts visible; a lone tap hides it → immersiveSticky. The
      // tap resolves after the double-tap window (~300ms).
      await tester.tap(find.byType(PageView));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    });
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
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
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

  group('system colors reach the app themes', () {
    const accent = Color(0xFF3366CC);

    setUp(() {
      // dynamic_color's channel is the platform boundary: a desktop accent.
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        DynamicColorPlugin.channel,
        (call) async => call.method == DynamicColorPlugin.accentColorMethodName
            ? accent.toARGB32()
            : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          DynamicColorPlugin.channel,
          null,
        ),
      );
    });

    MaterialApp app(WidgetTester tester) =>
        tester.widget<MaterialApp>(find.byType(MaterialApp));

    testWidgets('when the setting is on', (tester) async {
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
      await _pumpApp(
        tester,
        AppSettings.defaults().copyWith(
          guideCompleted: true,
          followSystemColors: true,
        ),
      );

      expect(
        app(tester).theme!.colorScheme.primary,
        ColorScheme.fromSeed(seedColor: accent).primary,
      );
      expect(
        app(tester).darkTheme!.colorScheme.primary,
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
        ).primary,
      );
    });

    testWidgets('and stay pink when it is off', (tester) async {
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
      await _pumpApp(
        tester,
        AppSettings.defaults().copyWith(guideCompleted: true),
      );

      expect(app(tester).theme!.colorScheme.primary, FuncTokens.primary);
      expect(app(tester).darkTheme!.colorScheme.primary, FuncTokens.primary);
    });
  });
}

/// Pumps the whole app signed in with [settings] and lets startup settle,
/// including the delayed auto-update check.
Future<void> _pumpApp(WidgetTester tester, AppSettings settings) async {
  // Widget coordinator gate — keeps startup quiet without a native side.
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('parfait/widget'),
    (call) async => false,
  );

  final container = ProviderContainer(
    overrides: [
      ...accountProviderOverrides(
        credentialStore: FakeCredentialStore(
          values: const {
            '100': Credential(accessToken: 'a', refreshToken: 'r'),
          },
        ),
        metadataRepository: FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 't')],
          currentId: '100',
        ),
      ),
      settingsRepositoryProvider.overrideWithValue(
        _MemorySettingsRepository(settings),
      ),
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
  addTearDown(container.dispose);

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

class _MemorySettingsRepository implements SettingsRepository {
  _MemorySettingsRepository(this.value);

  AppSettings value;

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async => value = settings;
}
