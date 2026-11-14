import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/log.dart';
import '../../core/platform/desktop_window_channel.dart';
import '../../core/platform/platform_caps.dart';
import '../layout/input_modality.dart';
import '../layout/window_layout_spec.dart';
import '../theme/func_semantic_tokens.dart';
import '../widgets/app_menu_button.dart';
import '../window/desktop_title_bar.dart';

/// Build-time toggle for the five-platform interactive shell emulator.
///
/// Always `false` in production builds unless explicitly enabled via
/// `--dart-define=PARFAIT_DEV_SHELL=true`, allowing tree-shaking to remove all
/// DevShell code and symbols from release binaries.
const bool kParfaitDevShell = bool.fromEnvironment('PARFAIT_DEV_SHELL');

/// Simulated OS target shell inside [DevShellHost].
enum DevShellPlatform {
  host('Host'),
  android('Android'),
  ios('iOS'),
  windows('Windows'),
  macos('macOS'),
  linux('Linux');

  const DevShellPlatform(this.label);
  final String label;
}

/// Simulated viewport preset inside [DevShellHost].
enum DevShellViewportPreset {
  host('Host', null, 0, EdgeInsets.zero, _FoldPreset.none),
  phone(
    'Phone 390',
    Size(390, 844),
    3.0,
    _androidPhonePadding,
    _FoldPreset.none,
  ),
  iphone('iPhone 393', Size(393, 852), 3.0, _iphonePadding, _FoldPreset.none),
  ipad('iPad 820', Size(820, 1180), 2.0, _ipadPadding, _FoldPreset.none),
  foldableBook(
    'Fold Book',
    Size(884, 740),
    2.5,
    _foldPadding,
    _FoldPreset.book,
  ),
  foldableTabletop(
    'Fold Table',
    Size(884, 740),
    2.5,
    _foldPadding,
    _FoldPreset.tabletop,
  ),
  desktop(
    'Desktop 1280',
    Size(1280, 800),
    1.5,
    EdgeInsets.zero,
    _FoldPreset.none,
  );

  const DevShellViewportPreset(
    this.label,
    this.logicalSize,
    this.defaultDpr,
    this.safePadding,
    this._foldPreset,
  );

  final String label;
  final Size? logicalSize;
  final double defaultDpr;
  final EdgeInsets safePadding;
  final _FoldPreset _foldPreset;
}

enum _FoldPreset { none, book, tabletop }

const double _phoneTopInset = FuncSpacing.xl;
const double _phoneBottomInset = FuncSpacing.lg;
const double _iphoneTopInset = 59;
const double _iphoneBottomInset = 34;
const double _ipadTopInset = FuncSpacing.xl;
const double _ipadBottomInset = 20;
const double _foldTopInset = 28;
const double _foldBottomInset = FuncSpacing.lg;

const EdgeInsets _androidPhonePadding = EdgeInsets.only(
  top: _phoneTopInset,
  bottom: _phoneBottomInset,
);
const EdgeInsets _iphonePadding = EdgeInsets.only(
  top: _iphoneTopInset,
  bottom: _iphoneBottomInset,
);
const EdgeInsets _ipadPadding = EdgeInsets.only(
  top: _ipadTopInset,
  bottom: _ipadBottomInset,
);
const EdgeInsets _foldPadding = EdgeInsets.only(
  top: _foldTopInset,
  bottom: _foldBottomInset,
);

/// Modality override selector for [DevShellHost].
enum DevShellModalityChoice {
  auto('Auto', null),
  touch('Touch', InputModality.touch),
  pointer('Pointer', InputModality.pointer);

  const DevShellModalityChoice(this.label, this.modality);
  final String label;
  final InputModality? modality;
}

const List<double?> _dprChoices = [null, 1.0, 1.5, 2.0, 3.0];

/// Programmatic controller for [DevShellHost], usable from toolbar or tests.
class DevShellController extends ChangeNotifier {
  DevShellPlatform _platform = DevShellPlatform.host;
  DevShellViewportPreset _viewport = DevShellViewportPreset.host;
  double? _dprOverride;
  DevShellModalityChoice _modalityChoice = DevShellModalityChoice.auto;
  bool _showCreaseOverlay = false;
  bool _collapsedToPill = false;
  Offset _pillOffset = const Offset(FuncSpacing.lg, FuncSpacing.xxxl);
  String? _lastCapturePath;

  DevShellPlatform get platform => _platform;
  DevShellViewportPreset get viewport => _viewport;
  double? get dprOverride => _dprOverride;
  DevShellModalityChoice get modalityChoice => _modalityChoice;
  bool get showCreaseOverlay => _showCreaseOverlay;
  bool get collapsedToPill => _collapsedToPill;
  Offset get pillOffset => _pillOffset;
  String? get lastCapturePath => _lastCapturePath;

  void setPlatform(DevShellPlatform next) {
    if (_platform == next) return;
    _platform = next;
    notifyListeners();
  }

  void setViewport(DevShellViewportPreset next) {
    if (_viewport == next) return;
    _viewport = next;
    notifyListeners();
  }

  void cycleDpr() {
    final index = _dprChoices.indexOf(_dprOverride);
    _dprOverride = _dprChoices[(index + 1) % _dprChoices.length];
    notifyListeners();
  }

  void cycleModality() {
    const values = DevShellModalityChoice.values;
    _modalityChoice = values[(_modalityChoice.index + 1) % values.length];
    notifyListeners();
  }

  void toggleCreaseOverlay() {
    _showCreaseOverlay = !_showCreaseOverlay;
    notifyListeners();
  }

  void setCollapsedToPill(bool collapsed) {
    if (_collapsedToPill == collapsed) return;
    _collapsedToPill = collapsed;
    notifyListeners();
  }

  void movePillBy(Offset delta, Size stageSize) {
    const pillExtent = 120.0;
    final nextX = (_pillOffset.dx + delta.dx).clamp(
      0.0,
      (stageSize.width - pillExtent).clamp(0.0, double.infinity),
    );
    final nextY = (_pillOffset.dy + delta.dy).clamp(
      0.0,
      (stageSize.height - FuncSpacing.xxl).clamp(0.0, double.infinity),
    );
    _pillOffset = Offset(nextX, nextY);
    notifyListeners();
  }

  void recordCapture(String path) {
    _lastCapturePath = path;
    notifyListeners();
  }
}

/// Interactive five-platform wrapper around [child] when `PARFAIT_DEV_SHELL`
/// is enabled.
///
/// Uses a persistent [GlobalKey] on [child] so platform, viewport, DPR,
/// modality, and toolbar collapse switches never tear down router, account,
/// or background image worker state.
class DevShellHost extends StatefulWidget {
  const DevShellHost({super.key, required this.child, this.controller});

  final Widget child;
  final DevShellController? controller;

  @override
  State<DevShellHost> createState() => DevShellHostState();
}

class DevShellHostState extends State<DevShellHost> {
  static const double _barHeight = 40;
  static const double _hingeWidth = 12;

  final GlobalKey _appKey = GlobalKey();
  final GlobalKey _captureKey = GlobalKey();
  OverlayEntry? _shellOverlayEntry;
  late DevShellController _controller;
  late bool _ownsController;
  bool _capturing = false;

  DevShellController get controller => _controller;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? DevShellController();
  }

  @override
  void didUpdateWidget(DevShellHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      if (_ownsController) _controller.dispose();
      _ownsController = widget.controller == null;
      _controller = widget.controller ?? DevShellController();
    }
  }

  @override
  void dispose() {
    _shellOverlayEntry?.remove();
    _shellOverlayEntry?.dispose();
    _shellOverlayEntry = null;
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  TargetPlatform _resolveTargetPlatform(DevShellPlatform p) => switch (p) {
    DevShellPlatform.host => defaultTargetPlatform,
    DevShellPlatform.android => TargetPlatform.android,
    DevShellPlatform.ios => TargetPlatform.iOS,
    DevShellPlatform.windows => TargetPlatform.windows,
    DevShellPlatform.macos => TargetPlatform.macOS,
    DevShellPlatform.linux => TargetPlatform.linux,
  };

  PlatformCaps _resolvePlatformCaps(DevShellPlatform p) => switch (p) {
    DevShellPlatform.host => PlatformCaps.system(),
    DevShellPlatform.android => const PlatformCaps(isAndroid: true),
    DevShellPlatform.ios => const PlatformCaps(isIOS: true),
    DevShellPlatform.windows => const PlatformCaps(isWindows: true),
    DevShellPlatform.macos => const PlatformCaps(isMacOS: true),
    DevShellPlatform.linux => const PlatformCaps(isLinux: true),
  };

  DesktopWindowPlatformMetrics? _resolveDesktopMetrics(
    DevShellPlatform p,
    TargetPlatform target,
  ) {
    if (p == DevShellPlatform.host) return null;
    return switch (target) {
      TargetPlatform.macOS => const DesktopWindowPlatformMetrics(
        usesSystemTitleBar: false,
        trafficLightWidth: 78,
        trafficLightHeight: 16,
      ),
      TargetPlatform.windows || TargetPlatform.linux =>
        const DesktopWindowPlatformMetrics(usesSystemTitleBar: false),
      _ => null,
    };
  }

  List<ui.DisplayFeature> _resolveDisplayFeatures(
    DevShellViewportPreset preset,
    Size viewportSize,
  ) {
    return switch (preset._foldPreset) {
      _FoldPreset.none => const [],
      _FoldPreset.book => [
        ui.DisplayFeature(
          bounds: Rect.fromLTWH(
            (viewportSize.width - _hingeWidth) / 2,
            0,
            _hingeWidth,
            viewportSize.height,
          ),
          type: ui.DisplayFeatureType.hinge,
          state: ui.DisplayFeatureState.postureHalfOpened,
        ),
      ],
      _FoldPreset.tabletop => [
        ui.DisplayFeature(
          bounds: Rect.fromLTWH(
            0,
            (viewportSize.height - _hingeWidth) / 2,
            viewportSize.width,
            _hingeWidth,
          ),
          type: ui.DisplayFeatureType.hinge,
          state: ui.DisplayFeatureState.postureHalfOpened,
        ),
      ],
    };
  }

  Future<String?> captureFrameToDisk() async {
    if (_capturing) return null;
    final boundary =
        _captureKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return null;
    _capturing = true;
    try {
      final hostDpr = MediaQuery.devicePixelRatioOf(context);
      final effectiveDpr =
          _controller.dprOverride ??
          (_controller.viewport.defaultDpr > 0
              ? _controller.viewport.defaultDpr
              : hostDpr);
      final image = await boundary.toImage(pixelRatio: effectiveDpr);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return null;

      final baseOut =
          Platform.environment['PARFAIT_DEV_SHELL_OUT'] ??
          '${Directory.systemTemp.path}/parfait-dev-shell';
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final fileName =
          'frame_${_controller.platform.name}_${_controller.viewport.name}_$stamp.png';
      final file = File('$baseOut/$fileName')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(data.buffer.asUint8List());
      if (mounted) _controller.recordCapture(file.path);
      log('DevShell exported frame: ${file.path}');
      return file.path;
    } finally {
      _capturing = false;
    }
  }

  Widget _buildViewportStage(BuildContext context, MediaQueryData hostMedia) {
    final platformChoice = _controller.platform;
    final preset = _controller.viewport;
    final targetPlatform = _resolveTargetPlatform(platformChoice);
    final caps = _resolvePlatformCaps(platformChoice);
    final desktopMetrics = _resolveDesktopMetrics(
      platformChoice,
      targetPlatform,
    );
    final showMacLights =
        targetPlatform == TargetPlatform.macOS &&
        platformChoice != DevShellPlatform.host;
    final effectiveModality =
        _controller.modalityChoice.modality ??
        defaultInputModalityFor(targetPlatform);

    final Widget persistentApp = KeyedSubtree(
      key: _appKey,
      child: widget.child,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final stageSize = constraints.biggest;
        final isHostViewport = preset == DevShellViewportPreset.host;
        final viewportSize = preset.logicalSize ?? stageSize;
        final dpr =
            _controller.dprOverride ??
            (preset.defaultDpr > 0
                ? preset.defaultDpr
                : hostMedia.devicePixelRatio);
        final displayFeatures = _resolveDisplayFeatures(preset, viewportSize);
        final padding = isHostViewport ? hostMedia.padding : preset.safePadding;
        final simulatedMedia = hostMedia.copyWith(
          size: viewportSize,
          devicePixelRatio: dpr,
          padding: padding,
          viewPadding: padding,
          displayFeatures: displayFeatures,
        );

        Widget frame = MediaQuery(
          data: simulatedMedia,
          child: Theme(
            data: Theme.of(context).copyWith(platform: targetPlatform),
            child: WindowEnvironmentOverride(
              displaySize: preset.logicalSize,
              targetPlatform: targetPlatform,
              platformCaps: caps,
              desktopMetrics: desktopMetrics,
              desktopActions: DesktopWindowActions.noop,
              showSimulatedTrafficLights: showMacLights,
              child: InputModalityScope(
                initialModality: effectiveModality,
                child: persistentApp,
              ),
            ),
          ),
        );

        if (_controller.showCreaseOverlay && displayFeatures.isNotEmpty) {
          frame = Stack(
            fit: StackFit.expand,
            children: [
              frame,
              IgnorePointer(
                child: CustomPaint(
                  painter: _CreaseOverlayPainter(displayFeatures),
                ),
              ),
            ],
          );
        }

        final boundary = RepaintBoundary(
          key: _captureKey,
          child: SizedBox(
            width: viewportSize.width,
            height: viewportSize.height,
            child: frame,
          ),
        );

        if (isHostViewport) {
          return boundary;
        }

        final colorScheme = Theme.of(context).colorScheme;
        return ColoredBox(
          color: colorScheme.surfaceContainerLowest,
          child: Center(
            child: FittedBox(
              fit: BoxFit.contain,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: colorScheme.outlineVariant,
                    width: 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: boundary,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final labelStyle = theme.textTheme.labelMedium;
    final dprLabel = _controller.dprOverride == null
        ? 'DPR Auto'
        : 'DPR ${_controller.dprOverride}x';
    final captureName = _controller.lastCapturePath?.split('/').last;

    return Material(
      color: colors.surfaceContainerHighest,
      child: Container(
        height: _barHeight,
        padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.sm),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.outlineVariant)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              Text('DEV SHELL', style: labelStyle),
              const SizedBox(width: FuncSpacing.sm),
              AppMenuButton<DevShellPlatform>(
                key: const ValueKey('dev-shell-platform-menu'),
                tooltip: 'Target Platform',
                edge: AppMenuEdge.start,
                entries: [
                  for (final p in DevShellPlatform.values)
                    AppMenuEntry<DevShellPlatform>(
                      value: p,
                      label: p.label,
                      checked: p == _controller.platform,
                    ),
                ],
                onSelected: (_, p) => _controller.setPlatform(p),
                anchorBuilder: (context, toggle) => TextButton.icon(
                  onPressed: toggle,
                  icon: const Icon(Icons.devices_outlined, size: 16),
                  label: Text(_controller.platform.label, style: labelStyle),
                ),
              ),
              const SizedBox(width: FuncSpacing.xs),
              AppMenuButton<DevShellViewportPreset>(
                key: const ValueKey('dev-shell-viewport-menu'),
                tooltip: 'Viewport Preset',
                edge: AppMenuEdge.start,
                entries: [
                  for (final v in DevShellViewportPreset.values)
                    AppMenuEntry<DevShellViewportPreset>(
                      value: v,
                      label: v.label,
                      checked: v == _controller.viewport,
                    ),
                ],
                onSelected: (_, v) => _controller.setViewport(v),
                anchorBuilder: (context, toggle) => TextButton.icon(
                  onPressed: toggle,
                  icon: const Icon(Icons.aspect_ratio, size: 16),
                  label: Text(_controller.viewport.label, style: labelStyle),
                ),
              ),
              const SizedBox(width: FuncSpacing.xs),
              TextButton.icon(
                key: const ValueKey('dev-shell-modality-btn'),
                onPressed: _controller.cycleModality,
                icon: Icon(
                  _controller.modalityChoice == DevShellModalityChoice.touch
                      ? Icons.touch_app_outlined
                      : Icons.mouse_outlined,
                  size: 16,
                ),
                label: Text(_controller.modalityChoice.label),
              ),
              TextButton.icon(
                key: const ValueKey('dev-shell-dpr-btn'),
                onPressed: _controller.cycleDpr,
                icon: const Icon(Icons.display_settings_outlined, size: 16),
                label: Text(dprLabel),
              ),
              IconButton(
                key: const ValueKey('dev-shell-crease-btn'),
                tooltip: 'Toggle Crease Ruler',
                isSelected: _controller.showCreaseOverlay,
                onPressed: _controller.toggleCreaseOverlay,
                icon: const Icon(Icons.view_column_outlined),
              ),
              IconButton(
                key: const ValueKey('dev-shell-capture-btn'),
                tooltip: 'Capture Frame PNG',
                onPressed: () => unawaited(captureFrameToDisk()),
                icon: const Icon(Icons.photo_camera_outlined),
              ),
              if (captureName != null) ...[
                const SizedBox(width: FuncSpacing.xs),
                Tooltip(
                  message: _controller.lastCapturePath!,
                  child: Text(captureName, style: theme.textTheme.labelSmall),
                ),
              ],
              const SizedBox(width: FuncSpacing.xs),
              IconButton(
                key: const ValueKey('dev-shell-collapse-btn'),
                tooltip: 'Collapse DevShell to Floating Pill',
                onPressed: () => _controller.setCollapsedToPill(true),
                icon: const Icon(Icons.expand_less),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingPill(BuildContext context, Size stageSize) {
    final colors = Theme.of(context).colorScheme;
    return Positioned(
      left: _controller.pillOffset.dx,
      top: _controller.pillOffset.dy,
      child: GestureDetector(
        onPanUpdate: (d) => _controller.movePillBy(d.delta, stageSize),
        child: Material(
          key: const ValueKey('dev-shell-floating-pill'),
          color: colors.inverseSurface,
          shape: const RoundedRectangleBorder(borderRadius: FuncShape.pill),
          elevation: 6,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Expand DevShell Controls',
                onPressed: () => _controller.setCollapsedToPill(false),
                icon: Icon(
                  Icons.tune_outlined,
                  color: colors.onInverseSurface,
                  size: 18,
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(end: FuncSpacing.sm),
                child: Text(
                  '${_controller.platform.label} · ${_controller.viewport.label}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onInverseSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShellBody(BuildContext context) {
    final hostMedia = MediaQuery.of(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final stage = _buildViewportStage(context, hostMedia);
        if (_controller.collapsedToPill) {
          return Stack(
            fit: StackFit.expand,
            children: [stage, _buildFloatingPill(context, hostMedia.size)],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildToolbar(context),
            Expanded(child: stage),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (Overlay.maybeOf(context) != null) {
      return _buildShellBody(context);
    }
    _shellOverlayEntry ??= OverlayEntry(builder: _buildShellBody);
    return Overlay(initialEntries: [_shellOverlayEntry!]);
  }
}

class _CreaseOverlayPainter extends CustomPainter {
  const _CreaseOverlayPainter(this.features);

  final List<ui.DisplayFeature> features;

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()
      ..color = const Color(0x4DE53935)
      ..style = PaintingStyle.fill;
    final linePaint = Paint()
      ..color = const Color(0xFFE53935)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (final feature in features) {
      final bounds = feature.bounds;
      if (bounds.width > 0 && bounds.height > 0) {
        canvas.drawRect(bounds, fillPaint);
        canvas.drawRect(bounds, linePaint);
      }
      if (bounds.height > bounds.width) {
        final cx = bounds.center.dx;
        canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), linePaint);
      } else {
        final cy = bounds.center.dy;
        canvas.drawLine(Offset(0, cy), Offset(size.width, cy), linePaint);
      }
    }
  }

  @override
  bool shouldRepaint(_CreaseOverlayPainter oldDelegate) =>
      oldDelegate.features != features;
}
