import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/layout/form_factor.dart';
import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/layout/window_layout_spec.dart';
import 'package:parfait/app/navigation/route_facade.dart';
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

const _defaultTrayLabels = TrayMenuLabels(
  tooltip: 'Parfait',
  showWindow: 'Show Window',
  downloads: 'Downloads',
  quit: 'Quit',
);

DesktopWindowActions _windowActions({
  VoidCallback? onClose,
  VoidCallback? onToggleFullScreen,
  VoidCallback? onStartDragging,
  VoidCallback? onTitleBarDoubleClick,
  void Function(List<DesktopTitleBarRegion>)? onRegionsChanged,
  void Function(List<DesktopTitleBarRegion>, double)?
  onRegionsWithHeightChanged,
}) => DesktopWindowActions(
  onMinimize: () {},
  onToggleMaximize: () {},
  onClose: onClose ?? () {},
  onToggleFullScreen: onToggleFullScreen ?? () {},
  onStartDragging: onStartDragging ?? () {},
  onTitleBarDoubleClick: onTitleBarDoubleClick ?? () {},
  onRegionsChanged: onRegionsChanged ?? (_) {},
  onRegionsWithHeightChanged: onRegionsWithHeightChanged,
);

DesktopWindowSession _windowSession({
  _FakeDesktopWindowAdapter? adapter,
  _FakeDesktopWindowHost? host,
  TrayPort trayPort = const NoopTrayPort(),
  bool closeToTray = false,
  ({double? width, double? height, double? x, double? y}) savedPlace = (
    width: null,
    height: null,
    x: null,
    y: null,
  ),
  Future<void> Function({
    double? width,
    double? height,
    double? x,
    double? y,
    required bool maximized,
  })?
  saveGeometry,
  Future<void> Function()? onBeforeDestroy,
  VoidCallback? onOpenDownloads,
  TargetPlatform? platformOverride,
  bool autoDispose = true,
}) {
  final session = DesktopWindowSession(
    adapter: adapter ?? _FakeDesktopWindowAdapter(),
    host: host ?? _FakeDesktopWindowHost(),
    trayPort: trayPort,
    readCloseToTray: () => closeToTray,
    readSavedPlace: () => savedPlace,
    saveGeometry:
        saveGeometry ?? ({width, height, x, y, required maximized}) async {},
    onBeforeDestroy: onBeforeDestroy,
    onOpenDownloads: onOpenDownloads,
    platformOverride: platformOverride,
  );
  if (autoDispose) addTearDown(session.dispose);
  return session;
}

Widget _desktopMaterialApp({
  TargetPlatform? platform,
  ThemeData? theme,
  Locale locale = const Locale('en', 'US'),
  Duration? themeAnimationDuration,
  required Widget home,
}) => MaterialApp(
  theme: theme ?? (platform == null ? null : ThemeData(platform: platform)),
  themeAnimationDuration: themeAnimationDuration ?? kThemeAnimationDuration,
  localizationsDelegates: appLocalizationsDelegates,
  supportedLocales: [locale],
  home: home,
);

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
        final savedRecords = <Map<String, Object?>>[];
        final session = _windowSession(
          adapter: adapter,
          savedPlace: (width: 900, height: 650, x: 80, y: 60),
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
        final saveCompleter = Completer<void>();
        final events = <String>[];
        adapter.onEvent = events.add;

        final session = _windowSession(
          adapter: adapter,
          saveGeometry: ({width, height, x, y, required maximized}) async {
            events.add('saveStart');
            await saveCompleter.future;
            events.add('saveEnd');
          },
        );

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
      'onWindowResize debounces without polling bounds and close runs onBeforeDestroy before destroy',
      () async {
        final adapter = _FakeDesktopWindowAdapter(size: const Size(1180, 780));
        final events = <String>[];
        adapter.onEvent = events.add;
        final session = _windowSession(
          adapter: adapter,
          saveGeometry: ({width, height, x, y, required maximized}) async {
            events.add('saveGeometry');
          },
          onBeforeDestroy: () async => events.add('beforeDestroy'),
        );

        for (var i = 0; i < 20; i++) {
          session.onWindowResize();
        }
        await pumpEventQueue();
        expect(adapter.getSizeCalls, 0);

        session.onWindowResized();
        await pumpEventQueue();
        expect(adapter.getSizeCalls, 1);

        await session.handleWindowClose();
        expect(
          events,
          containsAllInOrder([
            'saveGeometry',
            'beforeDestroy',
            'setPreventClose:false',
            'destroy',
          ]),
        );
      },
    );

    test(
      'captureOrdinary and saveNow ignore Windows minimized sentinel bounds',
      () async {
        // Minimizing on Windows reports iconic sentinel coordinates (-32000,
        // 160x28); captureOrdinary and saveNow must keep the ordinary bounds.
        double? savedW, savedH, savedX, savedY;
        final winAdapter = _FakeDesktopWindowAdapter(
          size: const Size(1240, 820),
          position: const Offset(120, 90),
        );
        final winSession = _windowSession(
          adapter: winAdapter,
          savedPlace: (width: 1240, height: 820, x: 120, y: 90),
          saveGeometry: ({width, height, x, y, required maximized}) async {
            savedW = width;
            savedH = height;
            savedX = x;
            savedY = y;
          },
        );
        await winSession.captureOrdinary();
        winAdapter
          ..minimized = true
          ..size = const Size(160, 28)
          ..position = const Offset(-32000, -32000);
        await winSession.captureOrdinary();
        await winSession.saveNow();
        expect((savedW, savedH, savedX, savedY), (1240, 820, 120, 90));
      },
    );

    test(
      'closeToTray hides when tray supported, destroys when unsupported, and quit forces exit',
      () async {
        final adapter = _FakeDesktopWindowAdapter(minimized: true);
        final tray = _FakeTrayPort(supported: true);
        var downloadsOpened = 0;

        final session = _windowSession(
          adapter: adapter,
          trayPort: tray,
          closeToTray: true,
          onOpenDownloads: () => downloadsOpened += 1,
        );
        await session.attach(initialLabels: _defaultTrayLabels);

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
        final unsupportedSession = _windowSession(
          adapter: unsupportedAdapter,
          closeToTray: true,
        );
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

        final session = _windowSession(
          adapter: adapter,
          host: host,
          savedPlace: (width: 1200, height: 760, x: 40, y: 40),
          saveGeometry: ({width, height, x, y, required maximized}) async {
            saved.add((width: width, height: height, maximized: maximized));
          },
        );
        await session.attach(initialLabels: _defaultTrayLabels);

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
        final session = _windowSession(trayPort: tray);

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

        final attachFuture = session.attach(initialLabels: _defaultTrayLabels);
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

    test(
      'macOS close exits fullscreen and hides to Dock; forceQuit destroys',
      () async {
        final adapter = _FakeDesktopWindowAdapter(fullScreen: true);
        final session = _windowSession(
          adapter: adapter,
          trayPort: _FakeTrayPort(supported: false),
          savedPlace: (width: 1280, height: 800, x: 80, y: 50),
          platformOverride: TargetPlatform.macOS,
        );
        await session.handleWindowClose();
        expect(adapter.calls, containsAllInOrder(['setFullScreen', 'hide']));
        expect(adapter.calls, isNot(contains('destroy')));
        await session.handleWindowClose(forceQuit: true);
        expect(adapter.calls, contains('destroy'));
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
        await port.initialize(labels: _defaultTrayLabels);
        await port.updateLabels(_defaultTrayLabels);
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

    testWidgets(
      'desktop pointer layout handles 1x<->2x DPR transitions without throwing',
      (tester) async {
        tester.view
          ..devicePixelRatio = 1.0
          ..physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: const [Locale('zh', 'CN')],
            home: Scaffold(
              body: Row(
                children: [
                  SizedBox(
                    width: ShellRail.width,
                    child: ShellRail(
                      destinations: const [
                        FuncBottomNavDestination(
                          icon: Icons.home_outlined,
                          label: '推荐',
                        ),
                      ],
                      selectedIndex: 0,
                      form: FormFactor.pc,
                      expanded: false,
                      canToggle: true,
                      onToggle: () {},
                      onSelected: (_) {},
                    ),
                  ),
                  const Expanded(child: SizedBox.expand()),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          WindowLayoutSpec.of(
            tester.element(find.byType(ShellRail)),
          ).inputModality,
          InputModality.pointer,
        );

        // Simulate moving the window onto a 2x HiDPI display and back to 1x.
        tester.view
          ..devicePixelRatio = 2.0
          ..physicalSize = const Size(3840, 2160);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
        expect(find.byType(ShellRail), findsOneWidget);
        expect(
          WindowLayoutSpec.of(
            tester.element(find.byType(ShellRail)),
          ).devicePixelRatio,
          2.0,
        );

        tester.view
          ..devicePixelRatio = 1.0
          ..physicalSize = const Size(1280, 800);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
        expect(find.byType(ShellRail), findsOneWidget);
        expect(
          WindowLayoutSpec.of(
            tester.element(find.byType(ShellRail)),
          ).devicePixelRatio,
          1.0,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    test(
      'applicationShouldTerminate flushes saveNow and onBeforeDestroy bypassing closeToTray',
      () async {
        final adapter = _FakeDesktopWindowAdapter();
        final host = _FakeDesktopWindowHost();
        final tray = _FakeTrayPort(supported: true);
        var savedCount = 0;
        var destroyedCount = 0;
        final session = _windowSession(
          adapter: adapter,
          host: host,
          trayPort: tray,
          closeToTray: true,
          saveGeometry: ({width, height, x, y, required maximized}) async {
            savedCount++;
          },
          onBeforeDestroy: () async {
            destroyedCount++;
          },
          autoDispose: false,
        );
        // Uninitialized tray must fall back to destroy instead of hiding.
        await session.handleWindowClose();
        expect(adapter.calls, contains('destroy'));
        expect(adapter.calls, isNot(contains('hide')));
        adapter.calls.clear();
        await session.attach(initialLabels: _defaultTrayLabels);
        expect(host.terminateHandler, isNotNull);
        await host.terminateHandler!();
        expect(savedCount, 2);
        expect(destroyedCount, 2);
        expect(adapter.calls, isNot(contains('hide')));
        session.dispose();
        expect(host.terminateHandler, isNull);
      },
    );

    testWidgets(
      'DesktopWindowFrame publishes caption, maximize, and buttons regions with height',
      (tester) async {
        List<DesktopTitleBarRegion> published = const [];
        double publishedHeight = 0;
        await tester.pumpWidget(
          _desktopMaterialApp(
            platform: TargetPlatform.windows,
            locale: const Locale('en'),
            home: DesktopWindowFrame(
              metricsOverride: const DesktopWindowPlatformMetrics(
                usesSystemTitleBar: false,
              ),
              actionsOverride: _windowActions(
                onRegionsWithHeightChanged: (regions, height) {
                  published = regions;
                  publishedHeight = height;
                },
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump();
        expect(
          published.map((r) => r.kind),
          containsAll(['caption', 'maximize', 'buttons']),
        );
        expect(publishedHeight, greaterThan(0));
      },
    );
  });
}

class _FakeDesktopWindowAdapter implements DesktopWindowAdapter {
  _FakeDesktopWindowAdapter({
    this.size = const Size(1280, 800),
    this.position = const Offset(80, 50),
    this.maximized = false,
    this.minimized = false,
    this.fullScreen = false,
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

  Size size;
  Offset position;
  final bool maximized;
  bool minimized;
  bool fullScreen;
  final bool throwOnGetPosition;
  final Display _primaryDisplay;

  final List<String> calls = <String>[];
  void Function(String event)? onEvent;
  Size? lastSize;
  int getSizeCalls = 0;

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
  Future<Size> getSize() async {
    getSizeCalls++;
    return size;
  }

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
  Future<void> Function()? terminateHandler;
  final StreamController<DesktopWindowPlatformMetrics> _controller =
      StreamController<DesktopWindowPlatformMetrics>.broadcast();

  void emitMetrics(DesktopWindowPlatformMetrics metrics) =>
      _controller.add(metrics);

  @override
  void setApplicationShouldTerminateHandler(Future<void> Function()? handler) {
    terminateHandler = handler;
  }

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
