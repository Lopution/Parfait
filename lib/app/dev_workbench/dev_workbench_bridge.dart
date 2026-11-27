import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/credential.dart';
import '../../core/debug/dev_redaction.dart';
import '../../core/debug/dev_telemetry.dart';
import '../../core/debug/dev_workbench_agent.dart';
import '../../core/debug/frame_probe.dart';
import '../../core/download/download_providers.dart';
import '../../core/download/download_task.dart';
import '../../core/image/image_worker_providers.dart';
import '../../core/log.dart';
import '../../core/network/compat/network_providers.dart';
import '../../core/network/dev_transport_override.dart';
import '../../core/platform/app_storage_paths.dart';
import '../../core/platform/desktop_window_channel.dart';
import '../../core/platform/platform_caps.dart';
import '../../core/settings/settings_controller.dart';
import '../clipboard.dart';
import '../navigation/forward_history.dart';

const String _defineProfile = String.fromEnvironment(
  'PARFAIT_DEV_PROFILE_NAME',
);
const String _defineSource = String.fromEnvironment('PARFAIT_DEV_SOURCE');
const String _defineLoopback = String.fromEnvironment(
  'PARFAIT_DEV_LOOPBACK_URL',
);
const String _defineWorkbench = String.fromEnvironment('PARFAIT_WORKBENCH_URL');
const String _defineDevWorkbench = String.fromEnvironment(
  'PARFAIT_DEV_WORKBENCH_URL',
);
const String _defineToken = String.fromEnvironment('PARFAIT_WORKBENCH_TOKEN');
const String _defineDevToken = String.fromEnvironment(
  'PARFAIT_DEV_WORKBENCH_TOKEN',
);
const bool _defineFreshOnboarding = bool.fromEnvironment(
  'PARFAIT_DEV_FRESH_ONBOARDING',
);
const bool _defineVmExtensions = bool.fromEnvironment(
  'PARFAIT_DEV_VM_EXTENSIONS',
  defaultValue: !kReleaseMode,
);

@immutable
class DevClientOptions {
  const DevClientOptions({
    this.profileName = 'default',
    this.initialSourceMode = DevDataSourceMode.live,
    this.loopbackOrigin,
    this.workbenchUrl,
    this.workbenchToken,
    this.freshOnboarding = false,
    this.exposeVmExtensions = !kReleaseMode,
  });

  factory DevClientOptions.fromRuntime(
    List<String> args, [
    Map<String, String>? env,
  ]) {
    final sourceEnv = env ?? Platform.environment;
    final profile =
        _argValue(args, '--profile') ??
        _argValue(args, '--dev-profile') ??
        _nonEmpty(sourceEnv['PARFAIT_DEV_PROFILE_NAME']) ??
        _nonEmpty(_defineProfile);
    final rawSource =
        _argValue(args, '--source') ??
        _nonEmpty(sourceEnv['PARFAIT_DEV_SOURCE']) ??
        _nonEmpty(_defineSource);
    final rawLoopback =
        _argValue(args, '--loopback') ??
        _nonEmpty(sourceEnv['PARFAIT_DEV_LOOPBACK_URL']) ??
        _nonEmpty(_defineLoopback);
    final rawWorkbench =
        _argValue(args, '--workbench-url') ??
        _nonEmpty(sourceEnv['PARFAIT_WORKBENCH_URL']) ??
        _nonEmpty(sourceEnv['PARFAIT_DEV_WORKBENCH_URL']) ??
        _nonEmpty(_defineWorkbench) ??
        _nonEmpty(_defineDevWorkbench);
    final rawToken =
        _argValue(args, '--workbench-token') ??
        _nonEmpty(sourceEnv['PARFAIT_WORKBENCH_TOKEN']) ??
        _nonEmpty(sourceEnv['PARFAIT_DEV_WORKBENCH_TOKEN']) ??
        _nonEmpty(_defineToken) ??
        _nonEmpty(_defineDevToken);
    final fresh =
        args.contains('--fresh-onboarding') ||
        sourceEnv['PARFAIT_DEV_FRESH_ONBOARDING'] == '1' ||
        _defineFreshOnboarding;

    final workbenchUri = _parseLoopbackUri(rawWorkbench);
    final loopbackUri = _parseLoopbackUri(rawLoopback) ?? workbenchUri;
    final initialMode = switch (rawSource?.toLowerCase()) {
      'loopback' => DevDataSourceMode.loopback,
      'live' => DevDataSourceMode.live,
      _ =>
        rawLoopback != null && loopbackUri != null
            ? DevDataSourceMode.loopback
            : DevDataSourceMode.live,
    };

    return DevClientOptions(
      profileName: profile ?? 'default',
      initialSourceMode: initialMode,
      loopbackOrigin: loopbackUri,
      workbenchUrl: workbenchUri,
      workbenchToken: rawToken,
      freshOnboarding: fresh,
      exposeVmExtensions: _defineVmExtensions,
    );
  }

  final String profileName;
  final DevDataSourceMode initialSourceMode;
  final Uri? loopbackOrigin;
  final Uri? workbenchUrl;
  final String? workbenchToken;
  final bool freshOnboarding;
  final bool exposeVmExtensions;

  DevTransportConfig get initialTransportConfig => DevTransportConfig(
    mode: initialSourceMode,
    loopbackOrigin: loopbackOrigin,
  );

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String? _argValue(List<String> args, String flag) {
    final prefix = '$flag=';
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg.startsWith(prefix)) {
        return _nonEmpty(arg.substring(prefix.length));
      }
      if (arg == flag && i + 1 < args.length) return _nonEmpty(args[i + 1]);
    }
    return null;
  }

  static Uri? _parseLoopbackUri(String? raw) {
    final text = _nonEmpty(raw);
    if (text == null) return null;
    final uri = Uri.tryParse(text);
    if (uri == null || !isAllowedLoopbackUri(uri)) return null;
    return uri;
  }
}

/// Attaches VM Service `ext.parfait.*` handlers and optional local Web Workbench
/// synchronization to [child] without altering production layout or state.
class DevWorkbenchHost extends ConsumerStatefulWidget {
  const DevWorkbenchHost({
    super.key,
    required this.router,
    required this.options,
    required this.child,
  });

  final GoRouter router;
  final DevClientOptions options;
  final Widget child;

  @override
  ConsumerState<DevWorkbenchHost> createState() => DevWorkbenchHostState();
}

/// State for [DevWorkbenchHost], exposing [dispatchDebugCommand] for widget
/// tests without needing live sockets inside `FakeAsync`.
class DevWorkbenchHostState extends ConsumerState<DevWorkbenchHost> {
  static const String loopbackAccountId = '900001';
  static const String loopbackAccessToken = 'dev-loopback-access';
  static const String loopbackRefreshToken = 'dev-loopback-refresh';

  static DevWorkbenchHostState? _active;
  static bool _extensionsRegistered = false;

  final GlobalKey _captureKey = GlobalKey(debugLabel: 'dev_workbench_capture');
  DevWorkbenchAgent? _agent;
  bool _loopbackBootstrapped = false;

  @override
  void initState() {
    super.initState();
    _active = this;
    if (widget.options.exposeVmExtensions) {
      _registerVmExtensionsOnce();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startAgentIfConfigured();
      if (widget.options.initialSourceMode == DevDataSourceMode.loopback &&
          !widget.options.freshOnboarding) {
        unawaited(_bootstrapLoopbackSessionIfEmpty());
      } else if (widget.options.initialSourceMode == DevDataSourceMode.live) {
        unawaited(_purgeLoopbackSessionIfSynthetic());
      }
    });
  }

  Uri _currentRouterUri() {
    try {
      return widget.router.state.uri;
    } on Object {
      return widget.router.routeInformationProvider.value.uri;
    }
  }

  String _currentTopRoute() {
    try {
      final top = widget.router.routerDelegate.currentConfiguration.lastOrNull;
      if (top != null && top.matchedLocation.isNotEmpty) {
        return top.matchedLocation;
      }
    } on Object {
      // Fall back to routeInformationProvider when delegate has no matches.
    }
    return widget.router.routeInformationProvider.value.uri.path;
  }

  @override
  void dispose() {
    if (identical(_active, this)) _active = null;
    _agent?.dispose();
    _agent = null;
    super.dispose();
  }

  void _startAgentIfConfigured() {
    final origin = widget.options.workbenchUrl;
    if (origin == null) return;
    _agent = DevWorkbenchAgent(
      workbenchOrigin: origin,
      clientId:
          '${Platform.operatingSystem}-${widget.options.profileName}-$pid',
      platformLabel: Platform.operatingSystem,
      token: widget.options.workbenchToken,
      buildSnapshot: _buildSnapshot,
      dispatchCommand: _dispatchCommand,
    )..start();
  }

  Future<void> _bootstrapLoopbackSessionIfEmpty() async {
    if (_loopbackBootstrapped || !mounted) return;
    _loopbackBootstrapped = true;
    try {
      final accountState = await ref.read(accountStoreProvider.future);
      if (!mounted) return;
      if (accountState.usableCurrent != null) return;
      if (ref.read(devTransportProvider).mode != DevDataSourceMode.loopback) {
        return;
      }
      await _performLoopbackSignIn();
    } on Object catch (error) {
      log('dev loopback session bootstrap skipped: $error');
    }
  }

  Future<void> _purgeLoopbackSessionIfSynthetic() async {
    if (!mounted) return;
    try {
      final accountState = await ref.read(accountStoreProvider.future);
      if (!mounted) return;
      final hasSynthetic = accountState.accounts.any(
        (account) => account.id == loopbackAccountId,
      );
      if (!hasSynthetic) return;
      final cred = await ref
          .read(credentialStoreProvider)
          .read(loopbackAccountId);
      if (!mounted) return;
      if (cred?.accessToken == loopbackAccessToken) {
        await ref
            .read(accountStoreProvider.notifier)
            .removeAccount(loopbackAccountId);
      }
    } on Object catch (error) {
      log('dev loopback synthetic session cleanup skipped: $error');
    }
  }

  Future<Map<String, Object?>> _performLoopbackSignIn() async {
    if (ref.read(devTransportProvider).mode != DevDataSourceMode.loopback) {
      throw StateError(
        'loopbackSignIn is allowed only in loopback source mode',
      );
    }
    await ref.read(settingsProvider.notifier).completeGuide();
    const account = Account(
      id: loopbackAccountId,
      userId: 900001,
      name: 'Parfait Dev',
      profileImageUrl: 'https://s.pximg.net/user-profile/parfait_dev.png',
    );
    const credential = Credential(
      accessToken: loopbackAccessToken,
      refreshToken: loopbackRefreshToken,
    );
    await ref
        .read(accountStoreProvider.notifier)
        .upsertAccount(account, credential);
    final path = _currentTopRoute();
    if (path == '/splash' ||
        path.startsWith('/welcome') ||
        path.startsWith('/login')) {
      widget.router.go('/recommended');
    }
    return {'ok': true, 'accountId': account.id};
  }

  static Map<String, Object?> _regionToMap(DesktopTitleBarRegion region) => {
    'left': region.rect.left,
    'top': region.rect.top,
    'right': region.rect.right,
    'bottom': region.rect.bottom,
    'width': region.rect.width,
    'height': region.rect.height,
    'kind': region.kind,
  };

  Future<Map<String, Object?>> _buildSnapshot({int? afterSeq}) async {
    final uri = _currentRouterUri();
    final topRoute = _currentTopRoute();
    final history = ForwardHistoryStack.ofRouter(widget.router);
    final transport = ref.read(devTransportProvider);
    final paths = ref.read(appStoragePathsProvider);
    final account = ref.read(accountStoreProvider).value?.usableCurrent;
    final policy = ref.read(networkAccessPolicyProvider);
    final workerSnapshot = await ref.read(imageWorkerProvider).snapshot();
    final windowHost = ref.read(desktopWindowHostProvider);
    final snapshotSource = windowHost is DesktopWindowSnapshotSource
        ? windowHost as DesktopWindowSnapshotSource
        : null;
    final winMetrics =
        snapshotSource?.lastMetrics ?? DesktopWindowPlatformMetrics.fallback;
    final titleBarHeight = snapshotSource?.lastTitleBarHeight ?? 0.0;
    final regions = snapshotSource?.lastTitleBarRegions ?? const [];
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    final logicalSize = view == null
        ? Size.zero
        : view.physicalSize / view.devicePixelRatio;
    final logs = afterSeq == null
        ? const <DevLogEntry>[]
        : DevTelemetry.instance.since(afterSeq, limit: 120);

    return redactDevMap({
      'platform': Platform.operatingSystem,
      'profileName': paths.profileName,
      'isDevIsolated': paths.isDev,
      'sourceMode': transport.mode.name,
      'loopbackOrigin': transport.loopbackOrigin?.toString(),
      'route': topRoute,
      'uri': uri.toString(),
      'canGoBack': history.canGoBack,
      'canGoForward': history.canGoForward,
      'hasUsableAccount': account != null,
      'viewport': {
        'width': logicalSize.width.round(),
        'height': logicalSize.height.round(),
        'dpr': view?.devicePixelRatio ?? 1.0,
      },
      'window': {
        'isWayland': winMetrics.isWayland,
        'usesSystemTitleBar': winMetrics.usesSystemTitleBar,
        'isFullScreen': winMetrics.isFullScreen,
        'isMaximized': winMetrics.isMaximized,
        'isActive': winMetrics.isActive,
        'trafficLightWidth': winMetrics.trafficLightWidth,
        'trafficLightHeight': winMetrics.trafficLightHeight,
        'hoveredButton': winMetrics.hoveredButton,
        'pressedButton': winMetrics.pressedButton,
        'titleBarHeight': titleBarHeight,
      },
      'nonClientRegions': {
        'titleBarHeight': titleBarHeight,
        'dragRegions': [
          for (final region in regions)
            if (region.kind == 'caption') _regionToMap(region),
        ],
        'interactiveRegions': [
          for (final region in regions)
            if (region.kind != 'caption') _regionToMap(region),
        ],
        'regions': [for (final region in regions) _regionToMap(region)],
      },
      'frameProbe': {
        'available': FrameProbe.available,
        'recording': FrameProbe.instance.recording,
        'frameCount': FrameProbe.instance.frameCount,
      },
      'imageWorker': {
        'state': workerSnapshot.state.name,
        'starts': workerSnapshot.starts,
        'inFlight': workerSnapshot.status?.inFlight,
        'queued': workerSnapshot.status?.queued,
        'diskEntries': workerSnapshot.status?.diskEntries,
      },
      'networkDiagnostics': [
        for (final event in policy.diagnostics.events.reversed.take(20))
          event.toMap(),
      ],
      'errors': {
        'count': DevTelemetry.instance.errorCount,
        'recent': [
          for (final e in DevTelemetry.instance.recentErrors(limit: 10))
            e.toJson(),
        ],
      },
      'storage': _storageSummary(paths, account?.id),
      'downloads': _downloadSummary(),
      'latestLogSeq': DevTelemetry.instance.latestSeq,
      if (afterSeq != null) 'logs': [for (final e in logs) e.toJson()],
    });
  }

  Map<String, Object?> _storageSummary(
    AppStoragePaths paths,
    String? accountId,
  ) {
    final prefs = paths.preferencesFile;
    final prefsExists = prefs?.existsSync() ?? false;
    return {
      'isDev': paths.isDev,
      'hasRootDir': paths.rootDir != null,
      'preferencesExists': prefsExists,
      'preferencesBytes': prefsExists ? prefs!.lengthSync() : 0,
      'accountId': accountId,
    };
  }

  Map<String, Object?> _downloadSummary() {
    final tasks = ref.read(downloadManagerProvider).tasks;
    return {
      'total': tasks.length,
      'succeeded': tasks
          .where((t) => t.status == DownloadStatus.succeeded)
          .length,
      'failed': tasks.where((t) => t.status == DownloadStatus.failed).length,
    };
  }

  @visibleForTesting
  Future<Map<String, Object?>> dispatchDebugCommand(
    String type, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) => _dispatchCommand(type, args);

  static num? _parseNumArg(Object? raw) {
    if (raw is num) return raw;
    if (raw is String) return num.tryParse(raw.trim());
    return null;
  }

  Future<Map<String, Object?>> _dispatchCommand(
    String type,
    Map<String, Object?> args,
  ) async {
    switch (type) {
      case 'snapshot':
        final afterSeq = _parseNumArg(args['afterSeq'])?.toInt();
        return _buildSnapshot(afterSeq: afterSeq);
      case 'navigate':
        final path = args['path']?.toString() ?? '';
        if (!_isValidRoutePath(path)) {
          throw ArgumentError.value(path, 'path', 'invalid internal route');
        }
        widget.router.go(path);
        return {'ok': true, 'path': path};
      case 'history':
        final action = args['action']?.toString();
        final stack = ForwardHistoryStack.ofRouter(widget.router);
        final moved = switch (action) {
          'back' => await stack.goBack(),
          'forward' => await stack.goForward(),
          _ => throw ArgumentError.value(action, 'action'),
        };
        return {'ok': moved, 'action': action};
      case 'setSourceMode':
        final rawMode = args['mode']?.toString();
        final nextMode = switch (rawMode) {
          'live' => DevDataSourceMode.live,
          'loopback' => DevDataSourceMode.loopback,
          _ => throw ArgumentError.value(rawMode, 'mode'),
        };
        final rawOrigin = args['loopbackOrigin']?.toString();
        Uri? origin;
        if (rawOrigin != null && rawOrigin.isNotEmpty) {
          origin = Uri.tryParse(rawOrigin);
          if (origin == null || !isAllowedLoopbackUri(origin)) {
            throw ArgumentError.value(rawOrigin, 'loopbackOrigin');
          }
        }
        ref
            .read(devTransportProvider.notifier)
            .setMode(nextMode, loopbackOrigin: origin);
        if (nextMode == DevDataSourceMode.live) {
          await _purgeLoopbackSessionIfSynthetic();
        }
        return {
          'ok': true,
          'mode': nextMode.name,
          'loopbackOrigin': ref
              .read(devTransportProvider)
              .loopbackOrigin
              ?.toString(),
        };
      case 'resizeWindow':
        final w = _parseNumArg(args['width'])?.toDouble();
        final h = _parseNumArg(args['height'])?.toDouble();
        if (w == null || h == null) {
          throw ArgumentError('width and height are required');
        }
        final clampedW = w.clamp(320.0, 3840.0);
        final clampedH = h.clamp(320.0, 2160.0);
        if (PlatformCaps.system().isDesktop) {
          await windowManager.setSize(Size(clampedW, clampedH));
        }
        return {'ok': true, 'width': clampedW, 'height': clampedH};
      case 'findBounds':
        final kind = args['kind']?.toString();
        final query = args['query']?.toString();
        return _findElementBounds(
          keyName: kind == 'key' ? query : args['key']?.toString(),
          semanticsLabel: kind == 'semantics'
              ? query
              : args['semantics']?.toString(),
          text: kind == 'text' ? query : args['text']?.toString(),
        );
      case 'frameProbe':
        final action = args['action']?.toString() ?? 'summary';
        if (action == 'start') FrameProbe.instance.start();
        if (action == 'stop') FrameProbe.instance.stop();
        return {
          'ok': true,
          'recording': FrameProbe.instance.recording,
          'frameCount': FrameProbe.instance.frameCount,
        };
      case 'loopbackSignIn':
        return _performLoopbackSignIn();
      case 'captureScreenshot':
        return _captureScreenshot();
      case 'readClipboard':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        return {'ok': true, 'text': data?.text};
      case 'writeClipboard':
        final text = args['text']?.toString() ?? '';
        await writeClipboardForDevHarness(text);
        return {'ok': true, 'length': text.length};
      case 'checkFile':
        return _checkIsolatedFile(args['relPath']?.toString() ?? '');
      default:
        throw UnsupportedError('unknown command: $type');
    }
  }

  Map<String, Object?> _checkIsolatedFile(String relPath) {
    final root = ref.read(appStoragePathsProvider).rootDir;
    if (root == null) {
      throw StateError('checkFile requires isolated dev storage root');
    }
    final normalized = p.normalize(relPath.trim());
    if (normalized.isEmpty ||
        p.isAbsolute(normalized) ||
        normalized == '..' ||
        normalized.startsWith('..${p.separator}') ||
        normalized.startsWith('../')) {
      throw ArgumentError.value(
        relPath,
        'relPath',
        'must stay inside dev root',
      );
    }
    final candidate = File(p.normalize(p.join(root.path, normalized)));
    if (!p.isWithin(root.path, candidate.path)) {
      throw ArgumentError.value(relPath, 'relPath', 'escapes dev root');
    }
    final exists = candidate.existsSync();
    return {
      'ok': true,
      'exists': exists,
      'bytes': exists ? candidate.lengthSync() : 0,
    };
  }

  static bool _isValidRoutePath(String path) {
    if (!path.startsWith('/') || path.length > 256) return false;
    if (path.contains('://') ||
        path.contains('\\') ||
        RegExp(r'[\r\n\s]').hasMatch(path)) {
      return false;
    }
    final rawPath = path.split('?').first.split('#').first;
    final segments = rawPath.split('/');
    if (segments.contains('..') || segments.contains('.')) return false;
    return true;
  }

  Map<String, Object?> _findElementBounds({
    String? keyName,
    String? semanticsLabel,
    String? text,
  }) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return {'found': false};
    if ((keyName == null || keyName.isEmpty) &&
        (semanticsLabel == null || semanticsLabel.isEmpty) &&
        (text == null || text.isEmpty)) {
      return {'found': false};
    }
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    final dpr = view?.devicePixelRatio ?? 1.0;
    final logicalSize = view == null
        ? Size.zero
        : view.physicalSize / (dpr > 0 ? dpr : 1.0);
    Rect? inViewportMatch;
    Rect? fallbackMatch;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Offstage && widget.offstage) return;
      if (widget is TickerMode && !widget.enabled) return;
      if (widget is Visibility && !widget.visible) return;
      bool hits = false;
      final widgetKey = widget.key;
      if (keyName != null && keyName.isNotEmpty) {
        if (widgetKey is ValueKey<String> && widgetKey.value == keyName) {
          hits = true;
        } else if (widgetKey != null && widgetKey.toString() == keyName) {
          hits = true;
        }
      }
      if (!hits && semanticsLabel != null && semanticsLabel.isNotEmpty) {
        if (widget is Semantics &&
            (widget.properties.label == semanticsLabel ||
                widget.properties.tooltip == semanticsLabel)) {
          hits = true;
        } else if (widget is Tooltip && widget.message == semanticsLabel) {
          hits = true;
        }
      }
      if (!hits && text != null && text.isNotEmpty) {
        if (widget is Text) {
          final content = widget.data ?? widget.textSpan?.toPlainText();
          if (content == text) hits = true;
        } else if (widget is RichText && widget.text.toPlainText() == text) {
          hits = true;
        }
      }
      if (hits) {
        final ro = element.renderObject;
        if (ro is RenderBox && ro.hasSize && ro.attached && !ro.size.isEmpty) {
          final origin = ro.localToGlobal(Offset.zero);
          final candidate = origin & ro.size;
          final c = candidate.center;
          final inView =
              logicalSize.isEmpty ||
              (c.dx >= 0 &&
                  c.dx <= logicalSize.width &&
                  c.dy >= 0 &&
                  c.dy <= logicalSize.height);
          if (inView) {
            inViewportMatch = candidate;
          } else {
            fallbackMatch = candidate;
          }
        }
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    final rect = inViewportMatch ?? fallbackMatch;
    if (rect == null) return {'found': false};
    return {
      'found': true,
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
      'centerX': rect.center.dx,
      'centerY': rect.center.dy,
      'dpr': dpr,
      'physicalCenterX': (rect.center.dx * dpr).round(),
      'physicalCenterY': (rect.center.dy * dpr).round(),
    };
  }

  static void _registerVmExtensionsOnce() {
    if (_extensionsRegistered) return;
    _extensionsRegistered = true;
    const names = [
      'snapshot',
      'navigate',
      'history',
      'setSourceMode',
      'resizeWindow',
      'findBounds',
      'frameProbe',
      'loopbackSignIn',
      'captureScreenshot',
      'readClipboard',
      'writeClipboard',
      'checkFile',
    ];
    for (final name in names) {
      developer.registerExtension('ext.parfait.$name', (method, params) async {
        final host = _active;
        if (host == null || !host.mounted) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            'DevWorkbenchHost is not mounted',
          );
        }
        try {
          final args = Map<String, Object?>.from(params);
          final result = await host._dispatchCommand(name, args);
          return developer.ServiceExtensionResponse.result(
            jsonEncode(redactDevMap(result)),
          );
        } on Object catch (error) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.invalidParams,
            redactDevText(error.toString()),
          );
        }
      });
    }
  }

  Future<Map<String, Object?>> _captureScreenshot() async {
    final ro = _captureKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) {
      throw StateError('capture boundary is not ready');
    }
    final dpr =
        WidgetsBinding
            .instance
            .platformDispatcher
            .implicitView
            ?.devicePixelRatio ??
        1.0;
    final image = await ro.toImage(pixelRatio: dpr.clamp(1.0, 2.0));
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw StateError('failed to encode screenshot PNG');
      }
      final bytes = byteData.buffer.asUint8List();
      return {
        'ok': true,
        'width': image.width,
        'height': image.height,
        'mimeType': 'image/png',
        'pngBase64': base64Encode(bytes),
      };
    } finally {
      image.dispose();
    }
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: _captureKey, child: widget.child);
}
