import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/layout/form_factor.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/system_ui.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/shell_rail.dart';
import 'package:parfait/app/window/desktop_title_bar.dart';
import 'package:parfait/app/window/desktop_window.dart';
import 'package:parfait/core/platform/desktop_tray.dart';
import 'package:parfait/core/platform/desktop_window_channel.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'helpers/fake_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopWindowSession and Wayland resilience', () {
    test(
      'prepareDesktopWindow skips setPosition on Wayland and clamps size',
      () async {
        final adapter = _FakeDesktopWindowAdapter(
          primaryDisplay: const Display(
            id: 'dp-1',
            name: 'Primary',
            size: Size(1200, 900),
            visiblePosition: Offset.zero,
            visibleSize: Size(1200, 900),
          ),
        );
        final host = _FakeDesktopWindowHost(
          initial: const DesktopWindowPlatformMetrics(
            isWayland: true,
            usesSystemTitleBar: true,
          ),
        );

        await seedSettings(
          AppSettings.defaults().copyWith(
            windowWidth: 2000,
            windowHeight: 1600,
            windowX: 250,
            windowY: 180,
            windowMaximized: false,
          ),
        );

        await prepareDesktopWindow(
          adapter: adapter,
          host: host,
          settingsRepository: storedSettings(),
          supportedOverride: true,
        );

        expect(adapter.calls, contains('setMinimumSize'));
        expect(adapter.calls, contains('setSize'));
        expect(adapter.calls, isNot(contains('setPosition')));
        expect(adapter.lastSize!.width, lessThanOrEqualTo(1200));
        expect(adapter.calls, isNot(contains('show')));
      },
    );

    test(
      'saveNow still persists size and maximized when getPosition throws',
      () async {
        final adapter = _FakeDesktopWindowAdapter(
          size: const Size(1024, 720),
          maximized: true,
          throwOnGetPosition: true,
        );
        final host = _FakeDesktopWindowHost();
        final savedRecords = <Map<String, Object?>>[];
        final session = DesktopWindowSession(
          adapter: adapter,
          host: host,
          trayPort: const NoopTrayPort(),
          readCloseToTray: () => false,
          readSavedPlace: () => (width: 900, height: 650, x: 80, y: 60),
          saveGeometry: ({width, height, x, y, required maximized}) async {
            savedRecords.add({
              'width': width,
              'height': height,
              'x': x,
              'y': y,
              'maximized': maximized,
            });
          },
        );
        addTearDown(session.dispose);

        await session.saveNow();

        expect(savedRecords, hasLength(1));
        expect(savedRecords.single['width'], 900);
        expect(savedRecords.single['height'], 650);
        expect(savedRecords.single['x'], 80);
        expect(savedRecords.single['y'], 60);
        expect(savedRecords.single['maximized'], isTrue);
      },
    );

    test(
      'close flushes geometry save before setPreventClose(false) and destroy',
      () async {
        final adapter = _FakeDesktopWindowAdapter(size: const Size(1180, 780));
        final host = _FakeDesktopWindowHost();
        final saveCompleter = Completer<void>();
        final events = <String>[];
        adapter.onEvent = events.add;

        final session = DesktopWindowSession(
          adapter: adapter,
          host: host,
          trayPort: const NoopTrayPort(),
          readCloseToTray: () => false,
          readSavedPlace: () => (width: null, height: null, x: null, y: null),
          saveGeometry: ({width, height, x, y, required maximized}) async {
            events.add('saveStart');
            await saveCompleter.future;
            events.add('saveEnd');
          },
        );
        addTearDown(session.dispose);

        final closing = session.handleWindowClose();
        await pumpEventQueue();

        expect(events, ['saveStart']);
        expect(adapter.calls, isNot(contains('destroy')));

        saveCompleter.complete();
        await closing;

        expect(events, [
          'saveStart',
          'saveEnd',
          'setPreventClose:false',
          'destroy',
        ]);
      },
    );

    test(
      'closeToTray hides when tray supported, destroys when unsupported, and quit forces exit',
      () async {
        final adapter = _FakeDesktopWindowAdapter(minimized: true);
        final host = _FakeDesktopWindowHost();
        final tray = _FakeTrayPort(supported: true);
        var downloadsOpened = 0;

        final session = DesktopWindowSession(
          adapter: adapter,
          host: host,
          trayPort: tray,
          readCloseToTray: () => true,
          readSavedPlace: () => (width: null, height: null, x: null, y: null),
          saveGeometry: ({width, height, x, y, required maximized}) async {},
          onOpenDownloads: () => downloadsOpened += 1,
        );
        addTearDown(session.dispose);
        await session.attach(
          initialLabels: const TrayMenuLabels(
            tooltip: 'Parfait',
            showWindow: 'Show Window',
            downloads: 'Downloads',
            quit: 'Quit',
          ),
        );

        await session.handleWindowClose();
        expect(adapter.calls, contains('hide'));
        expect(adapter.calls, isNot(contains('destroy')));

        tray.emit(TrayAction.openDownloads);
        await pumpEventQueue();
        expect(adapter.calls, containsAllInOrder(['restore', 'show', 'focus']));
        expect(downloadsOpened, 1);

        tray.emit(TrayAction.quit);
        await pumpEventQueue();
        expect(
          adapter.calls,
          containsAllInOrder(['setPreventClose:false', 'destroy']),
        );

        // Unsupported tray host must destroy cleanly instead of stranding window hidden.
        final unsupportedAdapter = _FakeDesktopWindowAdapter();
        final unsupportedSession = DesktopWindowSession(
          adapter: unsupportedAdapter,
          host: _FakeDesktopWindowHost(),
          trayPort: const NoopTrayPort(),
          readCloseToTray: () => true,
          readSavedPlace: () => (width: null, height: null, x: null, y: null),
          saveGeometry: ({width, height, x, y, required maximized}) async {},
        );
        addTearDown(unsupportedSession.dispose);

        await unsupportedSession.handleWindowClose();
        expect(unsupportedAdapter.calls, contains('destroy'));
        expect(unsupportedAdapter.calls, isNot(contains('hide')));
      },
    );

    test(
      'toggleFullScreen routes through native host when !usesSystemTitleBar and guards ordinary geometry',
      () async {
        final adapter = _FakeDesktopWindowAdapter(size: const Size(1200, 760));
        late final _FakeDesktopWindowHost host;
        host = _FakeDesktopWindowHost(
          initial: const DesktopWindowPlatformMetrics(
            usesSystemTitleBar: false,
          ),
          onCommand: (cmd) {
            if (cmd == DesktopWindowCommand.toggleFullScreen) {
              host.emitMetrics(
                const DesktopWindowPlatformMetrics(
                  usesSystemTitleBar: false,
                  isFullScreen: true,
                ),
              );
            }
          },
        );
        final saved = <({double? width, double? height, bool maximized})>[];

        final session = DesktopWindowSession(
          adapter: adapter,
          host: host,
          trayPort: const NoopTrayPort(),
          readCloseToTray: () => false,
          readSavedPlace: () => (width: 1200, height: 760, x: 40, y: 40),
          saveGeometry: ({width, height, x, y, required maximized}) async {
            saved.add((width: width, height: height, maximized: maximized));
          },
        );
        addTearDown(session.dispose);
        await session.attach(
          initialLabels: const TrayMenuLabels(
            tooltip: 'Parfait',
            showWindow: 'Show Window',
            downloads: 'Downloads',
            quit: 'Quit',
          ),
        );

        await session.toggleFullScreen();
        expect(host.commands, [DesktopWindowCommand.toggleFullScreen]);
        expect(adapter.calls, isNot(contains('setFullScreen')));
        expect(session.metrics.value.isFullScreen, isTrue);

        // Even if adapter.isFullScreen still reports false, fullscreen guard skips save.
        await session.captureOrdinary();
        await session.saveNow();
        expect(saved, isEmpty);
      },
    );

    test(
      'attach applies latest localized tray labels and flushes mid-init updates',
      () async {
        final supportGate = Completer<void>();
        final initGate = Completer<void>();
        final tray = _FakeTrayPort(
          supported: true,
          isSupportedGate: supportGate.future,
          initializeGate: initGate.future,
        );
        final session = DesktopWindowSession(
          adapter: _FakeDesktopWindowAdapter(),
          host: _FakeDesktopWindowHost(),
          trayPort: tray,
          readCloseToTray: () => false,
          readSavedPlace: () => (width: null, height: null, x: null, y: null),
          saveGeometry: ({width, height, x, y, required maximized}) async {},
        );
        addTearDown(session.dispose);

        const en = TrayMenuLabels(
          tooltip: 'Parfait',
          showWindow: 'Show Window',
          downloads: 'Downloads',
          quit: 'Quit',
        );
        const zh = TrayMenuLabels(
          tooltip: 'Parfait',
          showWindow: '显示窗口',
          downloads: '下载任务',
          quit: '退出',
        );
        const ja = TrayMenuLabels(
          tooltip: 'Parfait',
          showWindow: 'ウィンドウを表示',
          downloads: 'ダウンロード',
          quit: '終了',
        );

        final attachFuture = session.attach(initialLabels: en);
        await session.updateTrayLabels(zh);
        supportGate.complete();
        await pumpEventQueue();
        expect(tray.initializedLabels, [zh]);

        await session.updateTrayLabels(ja);
        initGate.complete();
        await attachFuture;
        expect(tray.updatedLabels, [ja]);
      },
    );
  });

  group('MethodChannel fallbacks and Wayland env detection', () {
    test(
      'MethodChannelTrayPort returns false safely on MissingPluginException',
      () async {
        final port = MethodChannelTrayPort(
          channel: const MethodChannel('parfait/test_missing_tray'),
        );
        addTearDown(port.dispose);

        expect(await port.isSupported(), isFalse);
        await port.initialize(
          labels: const TrayMenuLabels(
            tooltip: 'Parfait',
            showWindow: 'Show',
            downloads: 'Downloads',
            quit: 'Quit',
          ),
        );
        await port.updateLabels(
          const TrayMenuLabels(
            tooltip: 'Parfait',
            showWindow: 'Show',
            downloads: 'Downloads',
            quit: 'Quit',
          ),
        );
      },
    );

    test(
      'detectLinuxWaylandFromEnv respects XDG_SESSION_TYPE and WAYLAND_DISPLAY',
      () {
        expect(
          detectLinuxWaylandFromEnv({'XDG_SESSION_TYPE': 'wayland'}),
          isTrue,
        );
        expect(
          detectLinuxWaylandFromEnv({
            'XDG_SESSION_TYPE': 'x11',
            'WAYLAND_DISPLAY': 'wayland-0',
          }),
          isFalse,
        );
        expect(
          detectLinuxWaylandFromEnv({'WAYLAND_DISPLAY': 'wayland-0'}),
          isTrue,
        );
        expect(detectLinuxWaylandFromEnv({}), isFalse);
      },
    );

    test('PlatformCaps enables inbound URI intents on desktop targets', () {
      expect(
        const PlatformCaps(isWindows: true).supportsInboundIntents,
        isTrue,
      );
      expect(const PlatformCaps(isMacOS: true).supportsInboundIntents, isTrue);
      expect(const PlatformCaps(isLinux: true).supportsInboundIntents, isTrue);
    });
  });

  group('DesktopWindowFrame and single-button chrome', () {
    testWidgets(
      'Windows custom chrome renders single button set, raises padding, handles F11 & dark bars',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        var fullScreenToggles = 0;
        var closeClicks = 0;
        List<DesktopTitleBarRegion> lastRegions = const [];
        final barsController = DesktopSystemBarsController();
        addTearDown(barsController.dispose);
        final showDarkRoute = ValueNotifier<bool>(false);
        addTearDown(showDarkRoute.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: replicaTheme(
              Brightness.light,
            ).copyWith(platform: TargetPlatform.windows),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: const [Locale('en', 'US')],
            home: MotionScope(
              reduce: false,
              speed: AnimationSpeed.normal,
              pressFeedback: true,
              child: DesktopSystemBarsScope(
                controller: barsController,
                child: DesktopWindowFrame(
                  metricsOverride: const DesktopWindowPlatformMetrics(
                    usesSystemTitleBar: false,
                  ),
                  actionsOverride: DesktopWindowActions(
                    onMinimize: () {},
                    onToggleMaximize: () {},
                    onClose: () => closeClicks += 1,
                    onToggleFullScreen: () => fullScreenToggles += 1,
                    onStartDragging: () {},
                    onTitleBarDoubleClick: () {},
                    onRegionsChanged: (regions) => lastRegions = regions,
                  ),
                  child: Builder(
                    builder: (context) {
                      final chrome = DesktopChromeMetrics.of(context);
                      final mq = MediaQuery.of(context);
                      expect(chrome.hasCustomChrome, isTrue);
                      expect(chrome.showCustomButtons, isTrue);
                      expect(mq.padding.top, 32);
                      return ValueListenableBuilder<bool>(
                        valueListenable: showDarkRoute,
                        builder: (context, dark, _) => FuncSystemBars(
                          background: dark ? Brightness.dark : Brightness.light,
                          child: Row(
                            children: [
                              SizedBox(
                                width: ShellRail.width,
                                child: ShellRail(
                                  destinations: const [
                                    FuncBottomNavDestination(
                                      icon: Icons.home_outlined,
                                      label: 'Home',
                                    ),
                                  ],
                                  selectedIndex: 0,
                                  onSelected: (_) {},
                                  form: FormFactor.pc,
                                  expanded: false,
                                  onToggle: () {},
                                  onBookmarks: () {},
                                  onDownloads: () {},
                                ),
                              ),
                              const Expanded(
                                child: Scaffold(
                                  appBar: AppTopBar(title: Text('Explore')),
                                  body: SizedBox(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const Key('desktop-window-minimize')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('desktop-window-maximize')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('desktop-window-close')), findsOneWidget);
        expect(
          lastRegions.map((r) => r.kind).toSet(),
          containsAll(['caption', 'maximize']),
        );

        await tester.tap(find.byKey(const Key('desktop-window-close')));
        expect(closeClicks, 1);

        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        await tester.pump();
        expect(fullScreenToggles, 1);

        showDarkRoute.value = true;
        await tester.pump();
        await tester.pump();
        expect(barsController.brightness.value, Brightness.dark);
      },
    );

    testWidgets(
      'Windows fullscreen hides chrome and reveals hover cluster cleanly',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: const [Locale('en', 'US')],
            home: MotionScope(
              reduce: false,
              speed: AnimationSpeed.normal,
              pressFeedback: true,
              child: DesktopWindowFrame(
                metricsOverride: const DesktopWindowPlatformMetrics(
                  usesSystemTitleBar: false,
                  isFullScreen: true,
                ),
                child: Builder(
                  builder: (context) {
                    final chrome = DesktopChromeMetrics.of(context);
                    expect(chrome.hasCustomChrome, isFalse);
                    expect(chrome.effectiveTopInset, 0);
                    expect(MediaQuery.paddingOf(context).top, 0);
                    return const SizedBox.expand();
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        addTearDown(gesture.removePointer);
        await gesture.addPointer(location: const Offset(600, 2));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.byKey(const Key('desktop-window-close')), findsOneWidget);
      },
    );

    testWidgets(
      'macOS reserves traffic lights with zero custom buttons, Linux suppresses duplicate chrome',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.macOS),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: const [Locale('en', 'US')],
            home: DesktopWindowFrame(
              metricsOverride: const DesktopWindowPlatformMetrics(
                usesSystemTitleBar: false,
                trafficLightWidth: 84,
                trafficLightHeight: 36,
              ),
              child: Builder(
                builder: (context) {
                  final chrome = DesktopChromeMetrics.of(context);
                  expect(chrome.hasCustomChrome, isTrue);
                  expect(chrome.showCustomButtons, isFalse);
                  expect(chrome.leadingInset, 84);
                  expect(chrome.titleBarHeight, 36);
                  expect(MediaQuery.paddingOf(context).top, 36);
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        expect(find.byKey(const Key('desktop-window-close')), findsNothing);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.linux),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: const [Locale('en', 'US')],
            home: DesktopWindowFrame(
              metricsOverride: const DesktopWindowPlatformMetrics(
                isWayland: true,
                usesSystemTitleBar: true,
              ),
              child: Builder(
                builder: (context) {
                  final chrome = DesktopChromeMetrics.of(context);
                  expect(chrome.hasCustomChrome, isFalse);
                  expect(chrome.showCustomButtons, isFalse);
                  expect(MediaQuery.paddingOf(context).top, 0);
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        expect(find.byKey(const Key('desktop-window-close')), findsNothing);
      },
    );

    testWidgets(
      'DesktopWindowFrame drops stale title-bar regions when fullscreen toggles while measure pending',
      (tester) async {
        final metrics = ValueNotifier(
          const DesktopWindowPlatformMetrics(usesSystemTitleBar: false),
        );
        addTearDown(metrics.dispose);
        final published = <List<DesktopTitleBarRegion>>[];
        final actions = DesktopWindowActions(
          onMinimize: () {},
          onToggleMaximize: () {},
          onClose: () {},
          onToggleFullScreen: () {},
          onStartDragging: () {},
          onTitleBarDoubleClick: () {},
          onRegionsChanged: published.add,
        );

        Widget buildTree() => MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: const [Locale('en', 'US')],
          home: ValueListenableBuilder<DesktopWindowPlatformMetrics>(
            valueListenable: metrics,
            builder: (context, value, _) => DesktopWindowFrame(
              metricsOverride: value,
              actionsOverride: actions,
              child: const SizedBox.expand(),
            ),
          ),
        );

        await tester.pumpWidget(buildTree(), phase: EnginePhase.paint);
        metrics.value = const DesktopWindowPlatformMetrics(
          usesSystemTitleBar: false,
          isFullScreen: true,
        );
        await tester.pump();

        expect(published, isNotEmpty);
        expect(published.last, isEmpty);
      },
    );

    testWidgets(
      'openDownloadsFromRouter skips pre-home routes, deduplicates downloads, and keeps rail',
      (tester) async {
        final rootKey = GlobalKey<NavigatorState>();
        final branchKey = GlobalKey<NavigatorState>();
        final router = GoRouter(
          navigatorKey: rootKey,
          initialLocation: '/splash',
          routes: [
            GoRoute(path: '/splash', builder: (_, _) => const SizedBox()),
            GoRoute(
              path: '/welcome',
              builder: (_, _) => const SizedBox(),
              routes: [
                GoRoute(path: 'language', builder: (_, _) => const SizedBox()),
              ],
            ),
            GoRoute(
              path: '/user-agreement',
              builder: (_, _) => const SizedBox(),
            ),
            GoRoute(path: '/login', builder: (_, _) => const SizedBox()),
            GoRoute(
              path: '/downloads',
              parentNavigatorKey: rootKey,
              builder: (_, _) => const SizedBox(),
            ),
            StatefulShellRoute.indexedStack(
              builder: (_, _, shell) => shell,
              branches: [
                StatefulShellBranch(
                  navigatorKey: branchKey,
                  routes: [
                    GoRoute(
                      path: '/recommended',
                      builder: (_, _) => const SizedBox(),
                      routes: [
                        GoRoute(
                          path: 'downloads',
                          builder: (_, _) => const SizedBox(),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(MaterialApp.router(routerConfig: router));

        for (final path in [
          '/splash',
          '/welcome',
          '/welcome/language',
          '/user-agreement',
          '/login',
        ]) {
          router.go(path);
          await tester.pumpAndSettle();
          openDownloadsFromRouter(router, rail: true);
          await tester.pumpAndSettle();
          expect(router.state.uri.path, path);
        }

        router.go('/recommended');
        await tester.pumpAndSettle();
        openDownloadsFromRouter(router, rail: true);
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/recommended/downloads');

        // Calling again when already on $root/downloads must not duplicate.
        openDownloadsFromRouter(router, rail: true);
        await tester.pumpAndSettle();
        expect(router.canPop(), isTrue);
        router.pop();
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/recommended');

        openDownloadsFromRouter(router, rail: false);
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/downloads');
        openDownloadsFromRouter(router, rail: false);
        await tester.pumpAndSettle();
        router.pop();
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/recommended');
      },
    );
  });
}

class _FakeDesktopWindowAdapter implements DesktopWindowAdapter {
  _FakeDesktopWindowAdapter({
    this.size = const Size(1280, 800),
    this.maximized = false,
    this.minimized = false,
    this.throwOnGetPosition = false,
    Display? primaryDisplay,
  }) : _primaryDisplay =
           primaryDisplay ??
           const Display(
             id: 'primary',
             name: 'Primary',
             size: Size(1920, 1080),
             visiblePosition: Offset.zero,
             visibleSize: Size(1920, 1080),
           );

  final Size size;
  final Offset position = const Offset(80, 50);
  final bool maximized;
  final bool minimized;
  final bool fullScreen = false;
  final bool throwOnGetPosition;
  final Display _primaryDisplay;

  final List<String> calls = <String>[];
  void Function(String event)? onEvent;
  Size? lastSize;

  void _record(String event) {
    calls.add(event);
    onEvent?.call(event);
  }

  @override
  Future<void> ensureInitialized() async => _record('ensureInitialized');

  @override
  Future<void> setMinimumSize(Size value) async => _record('setMinimumSize');

  @override
  Future<void> setSize(Size value) async {
    lastSize = value;
    _record('setSize');
  }

  @override
  Future<void> setPosition(Offset value) async => _record('setPosition');

  @override
  Future<void> maximize() async => _record('maximize');

  @override
  Future<void> unmaximize() async => _record('unmaximize');

  @override
  Future<void> minimize() async => _record('minimize');

  @override
  Future<void> restore() async => _record('restore');

  @override
  Future<void> show() async => _record('show');

  @override
  Future<void> focus() async => _record('focus');

  @override
  Future<void> hide() async => _record('hide');

  @override
  Future<void> close() async => _record('close');

  @override
  Future<void> destroy() async => _record('destroy');

  @override
  Future<void> setPreventClose(bool prevent) async =>
      _record('setPreventClose:$prevent');

  @override
  Future<void> setFullScreen(bool value) async => _record('setFullScreen');

  @override
  Future<bool> isFullScreen() async => fullScreen;

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<bool> isMinimized() async => minimized;

  @override
  Future<Size> getSize() async => size;

  @override
  Future<Offset> getPosition() async {
    if (throwOnGetPosition) {
      throw PlatformException(code: 'wayland_unsupported');
    }
    return position;
  }

  @override
  Future<Display> getPrimaryDisplay() async => _primaryDisplay;

  @override
  Future<List<Display>> getAllDisplays() async => [_primaryDisplay];

  @override
  void addListener(WindowListener listener) {}

  @override
  void removeListener(WindowListener listener) {}
}

class _FakeDesktopWindowHost implements DesktopWindowHost {
  _FakeDesktopWindowHost({
    DesktopWindowPlatformMetrics initial = const DesktopWindowPlatformMetrics(),
    void Function(DesktopWindowCommand command)? onCommand,
  }) : _initial = initial,
       _onCommand = onCommand;

  final DesktopWindowPlatformMetrics _initial;
  final void Function(DesktopWindowCommand command)? _onCommand;
  final List<DesktopWindowCommand> commands = <DesktopWindowCommand>[];
  final StreamController<DesktopWindowPlatformMetrics> _controller =
      StreamController<DesktopWindowPlatformMetrics>.broadcast();

  void emitMetrics(DesktopWindowPlatformMetrics metrics) =>
      _controller.add(metrics);

  @override
  Future<DesktopWindowPlatformMetrics> getMetrics() async => _initial;

  @override
  Stream<DesktopWindowPlatformMetrics> get metricsStream => _controller.stream;

  @override
  Future<void> setTitleBarMetrics({
    required List<DesktopTitleBarRegion> regions,
    double titleBarHeight = 0,
  }) async {}

  @override
  Future<void> performCommand(DesktopWindowCommand command) async {
    commands.add(command);
    _onCommand?.call(command);
  }

  @override
  Future<void> dispose() async => _controller.close();
}

class _FakeTrayPort implements TrayPort {
  _FakeTrayPort({
    required bool supported,
    Future<void>? isSupportedGate,
    Future<void>? initializeGate,
  }) : _supported = supported,
       _isSupportedGate = isSupportedGate,
       _initializeGate = initializeGate;

  final bool _supported;
  final Future<void>? _isSupportedGate;
  final Future<void>? _initializeGate;
  final List<TrayMenuLabels> initializedLabels = <TrayMenuLabels>[];
  final List<TrayMenuLabels> updatedLabels = <TrayMenuLabels>[];
  final StreamController<TrayAction> _controller =
      StreamController<TrayAction>.broadcast();

  void emit(TrayAction action) => _controller.add(action);

  @override
  Future<bool> isSupported() async {
    await _isSupportedGate;
    return _supported;
  }

  @override
  Future<void> initialize({required TrayMenuLabels labels}) async {
    initializedLabels.add(labels);
    await _initializeGate;
  }

  @override
  Future<void> updateLabels(TrayMenuLabels labels) async {
    updatedLabels.add(labels);
  }

  @override
  Stream<TrayAction> get actions => _controller.stream;

  @override
  Future<void> dispose() async => _controller.close();
}
