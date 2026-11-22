import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform/desktop_window_channel.dart';
import '../layout/window_layout_spec.dart';
import '../motion/motion_tokens.dart';
import '../system_ui.dart';
import '../theme/func_semantic_tokens.dart';
import 'desktop_caption_buttons.dart';
import 'desktop_fallback_chrome_stack.dart';
import 'desktop_title_bar_region_publisher.dart';

export 'desktop_caption_buttons.dart'
    show DesktopWindowCaptionButtons, SimulatedMacTrafficLights;

const double _windowsControlsWidth = kWindowsCaptionButtonWidth * 3;
const double _macFallbackTrafficLightWidth = 78;

void _noopAction() {}
void _noopRegions(List<DesktopTitleBarRegion> _) {}

/// Action callbacks exposed by [DesktopWindowScope] to [DesktopWindowFrame].
@immutable
class DesktopWindowActions {
  const DesktopWindowActions({
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
    required this.onToggleFullScreen,
    required this.onStartDragging,
    required this.onTitleBarDoubleClick,
    required this.onRegionsChanged,
    this.onRegionsWithHeightChanged,
    this.onRestoreEditMenu,
  });

  /// Non-interactive stub actions used in simulated desktop shells and review
  /// screenshots so caption buttons render in their enabled state.
  static const DesktopWindowActions noop = DesktopWindowActions(
    onMinimize: _noopAction,
    onToggleMaximize: _noopAction,
    onClose: _noopAction,
    onToggleFullScreen: _noopAction,
    onStartDragging: _noopAction,
    onTitleBarDoubleClick: _noopAction,
    onRegionsChanged: _noopRegions,
  );

  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;
  final VoidCallback onToggleFullScreen;
  final VoidCallback onStartDragging;
  final VoidCallback onTitleBarDoubleClick;
  final ValueChanged<List<DesktopTitleBarRegion>> onRegionsChanged;
  final void Function(
    List<DesktopTitleBarRegion> regions,
    double titleBarHeight,
  )?
  onRegionsWithHeightChanged;
  final VoidCallback? onRestoreEditMenu;
}

/// Bridges the process-level desktop window controller into [DesktopWindowFrame].
class DesktopWindowScope extends InheritedWidget {
  const DesktopWindowScope({
    super.key,
    required this.metrics,
    required this.actions,
    required super.child,
  });

  final ValueListenable<DesktopWindowPlatformMetrics> metrics;
  final DesktopWindowActions actions;

  static DesktopWindowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopWindowScope>();

  @override
  bool updateShouldNotify(DesktopWindowScope oldWidget) =>
      metrics != oldWidget.metrics || actions != oldWidget.actions;
}

/// Layout and inset metrics for custom frameless desktop window chrome.
///
/// Published above the router so `ShellRail`, `AppTopBar`, and immersive pages
/// clear native traffic lights or custom caption controls without double bars.
class DesktopChromeMetrics extends InheritedWidget {
  const DesktopChromeMetrics({
    super.key,
    this.titleBarHeight = 0,
    this.leadingInset = 0,
    this.trailingInset = 0,
    this.trafficLightSize = Size.zero,
    this.isFullScreen = false,
    this.isMaximized = false,
    this.isActive = true,
    this.usesSystemTitleBar = true,
    this.showCustomButtons = false,
    this.hostMetrics,
    this.actions,
    this.showSimulatedTrafficLights = false,
    this.brightnessListenable,
    required super.child,
  });

  const DesktopChromeMetrics._empty({required super.child})
    : titleBarHeight = 0,
      leadingInset = 0,
      trailingInset = 0,
      trafficLightSize = Size.zero,
      isFullScreen = false,
      isMaximized = false,
      isActive = true,
      usesSystemTitleBar = true,
      showCustomButtons = false,
      hostMetrics = null,
      actions = null,
      showSimulatedTrafficLights = false,
      brightnessListenable = null;

  final double titleBarHeight;
  final double leadingInset;
  final double trailingInset;
  final Size trafficLightSize;
  final bool isFullScreen;
  final bool isMaximized;
  final bool isActive;
  final bool usesSystemTitleBar;
  final bool showCustomButtons;
  final DesktopWindowPlatformMetrics? hostMetrics;
  final DesktopWindowActions? actions;
  final bool showSimulatedTrafficLights;
  final ValueListenable<Brightness>? brightnessListenable;

  DesktopChromeMetrics copyWith({
    double? titleBarHeight,
    double? leadingInset,
    double? trailingInset,
    Size? trafficLightSize,
    bool? isFullScreen,
    bool? isMaximized,
    bool? isActive,
    bool? usesSystemTitleBar,
    bool? showCustomButtons,
    DesktopWindowPlatformMetrics? hostMetrics,
    DesktopWindowActions? actions,
    bool? showSimulatedTrafficLights,
    ValueListenable<Brightness>? brightnessListenable,
    required Widget child,
  }) => DesktopChromeMetrics(
    titleBarHeight: titleBarHeight ?? this.titleBarHeight,
    leadingInset: leadingInset ?? this.leadingInset,
    trailingInset: trailingInset ?? this.trailingInset,
    trafficLightSize: trafficLightSize ?? this.trafficLightSize,
    isFullScreen: isFullScreen ?? this.isFullScreen,
    isMaximized: isMaximized ?? this.isMaximized,
    isActive: isActive ?? this.isActive,
    usesSystemTitleBar: usesSystemTitleBar ?? this.usesSystemTitleBar,
    showCustomButtons: showCustomButtons ?? this.showCustomButtons,
    hostMetrics: hostMetrics ?? this.hostMetrics,
    actions: actions ?? this.actions,
    showSimulatedTrafficLights:
        showSimulatedTrafficLights ?? this.showSimulatedTrafficLights,
    brightnessListenable: brightnessListenable ?? this.brightnessListenable,
    child: child,
  );

  bool get hasCustomChrome =>
      titleBarHeight > 0 && !isFullScreen && !usesSystemTitleBar;

  double get effectiveTopInset => hasCustomChrome ? titleBarHeight : 0;

  EdgeInsets get topSafePadding => EdgeInsets.only(top: effectiveTopInset);

  static DesktopChromeMetrics? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopChromeMetrics>();

  static DesktopChromeMetrics of(BuildContext context) =>
      maybeOf(context) ?? const DesktopChromeMetrics._empty(child: SizedBox());

  static DesktopChromeMetrics resolveData({
    required TargetPlatform platform,
    required DesktopWindowPlatformMetrics hostMetrics,
    required Widget child,
  }) {
    final isDesktop =
        !kIsWeb &&
        (platform == TargetPlatform.windows ||
            platform == TargetPlatform.macOS ||
            platform == TargetPlatform.linux);
    if (!isDesktop || hostMetrics.usesSystemTitleBar) {
      return DesktopChromeMetrics(
        isFullScreen: hostMetrics.isFullScreen,
        isMaximized: hostMetrics.isMaximized,
        isActive: hostMetrics.isActive,
        usesSystemTitleBar: true,
        child: child,
      );
    }
    if (hostMetrics.isFullScreen) {
      return DesktopChromeMetrics(
        isFullScreen: true,
        isMaximized: hostMetrics.isMaximized,
        isActive: hostMetrics.isActive,
        usesSystemTitleBar: false,
        child: child,
      );
    }
    if (platform == TargetPlatform.macOS) {
      final lightWidth = hostMetrics.trafficLightWidth > 0
          ? hostMetrics.trafficLightWidth
          : _macFallbackTrafficLightWidth;
      final lightHeight = hostMetrics.trafficLightHeight > 0
          ? hostMetrics.trafficLightHeight
          : FuncSpacing.xxl;
      final barHeight = math.max(FuncSpacing.xxl, lightHeight);
      return DesktopChromeMetrics(
        titleBarHeight: barHeight,
        leadingInset: lightWidth,
        trafficLightSize: Size(lightWidth, lightHeight),
        isMaximized: hostMetrics.isMaximized,
        isActive: hostMetrics.isActive,
        usesSystemTitleBar: false,
        child: child,
      );
    }
    return DesktopChromeMetrics(
      titleBarHeight: FuncSpacing.xxl,
      trailingInset: _windowsControlsWidth,
      isMaximized: hostMetrics.isMaximized,
      isActive: hostMetrics.isActive,
      usesSystemTitleBar: false,
      showCustomButtons: true,
      child: child,
    );
  }

  @override
  bool updateShouldNotify(DesktopChromeMetrics oldWidget) =>
      titleBarHeight != oldWidget.titleBarHeight ||
      leadingInset != oldWidget.leadingInset ||
      trailingInset != oldWidget.trailingInset ||
      trafficLightSize != oldWidget.trafficLightSize ||
      isFullScreen != oldWidget.isFullScreen ||
      isMaximized != oldWidget.isMaximized ||
      isActive != oldWidget.isActive ||
      usesSystemTitleBar != oldWidget.usesSystemTitleBar ||
      showCustomButtons != oldWidget.showCustomButtons ||
      hostMetrics != oldWidget.hostMetrics ||
      actions != oldWidget.actions ||
      showSimulatedTrafficLights != oldWidget.showSimulatedTrafficLights ||
      brightnessListenable != oldWidget.brightnessListenable;
}

/// Top-level frameless desktop chrome shell wrapping the router.
class DesktopWindowFrame extends StatefulWidget {
  const DesktopWindowFrame({
    super.key,
    required this.child,
    this.metricsOverride,
    this.actionsOverride,
    this.captionBrightnessOverride,
    this.showSimulatedTrafficLights = false,
    this.suppressOverlayBar = false,
  });

  final Widget child;
  final DesktopWindowPlatformMetrics? metricsOverride;
  final DesktopWindowActions? actionsOverride;
  final ValueListenable<Brightness>? captionBrightnessOverride;
  final bool showSimulatedTrafficLights;

  /// When true, omits the legacy `32dp` floating overlay title bar and its
  /// top padding reservation so an outer `DesktopCommandBar` owns the row.
  final bool suppressOverlayBar;

  @override
  State<DesktopWindowFrame> createState() => _DesktopWindowFrameState();
}

class _DesktopWindowFrameState extends State<DesktopWindowFrame> {
  final GlobalKey _dragKey = GlobalKey();
  final GlobalKey _maximizeKey = GlobalKey();
  final DesktopTitleBarRegionPublisher _regionPublisher =
      DesktopTitleBarRegionPublisher();

  bool _hoverReveal = false;
  bool _canToggleF11 = false;
  DesktopWindowActions? _lastActions;
  DesktopChromeMetrics? _lastChrome;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!mounted || !_canToggleF11) return false;
    final actions = _lastActions;
    if (actions == null) return false;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.f11 &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed) {
      actions.onToggleFullScreen();
      return true;
    }
    return false;
  }

  void _scheduleRegionPublish(
    DesktopWindowActions? actions,
    DesktopChromeMetrics chrome,
  ) {
    _lastActions = actions;
    _lastChrome = chrome;
    if (widget.suppressOverlayBar && !chrome.isFullScreen) {
      _regionPublisher.resetSignature();
      return;
    }
    _regionPublisher.schedulePublish(
      actions,
      isMounted: () => mounted,
      resolve: () {
        final currentActions = _lastActions;
        final currentChrome = _lastChrome;
        if (currentActions == null || currentChrome == null) return null;
        final regions = <DesktopTitleBarRegion>[];
        if (currentChrome.hasCustomChrome) {
          DesktopTitleBarRegionPublisher.addRegion(
            regions,
            _dragKey,
            'caption',
          );
          if (currentChrome.showCustomButtons) {
            DesktopTitleBarRegionPublisher.addRegion(
              regions,
              _maximizeKey,
              'maximize',
            );
          }
        }
        return (
          actions: currentActions,
          regions: regions,
          titleBarHeight: null,
        );
      },
    );
  }

  Widget _buildFrame(
    BuildContext context,
    DesktopWindowPlatformMetrics hostMetrics,
    DesktopWindowActions? actions,
    ValueListenable<Brightness>? brightnessListenable,
    bool showSimulatedTrafficLights,
  ) {
    final platform = Theme.of(context).platform;
    final resolved = DesktopChromeMetrics.resolveData(
      platform: platform,
      hostMetrics: hostMetrics,
      child: widget.child,
    );
    _scheduleRegionPublish(actions, resolved);

    final mediaQuery = MediaQuery.of(context);
    final adjustedMediaQuery =
        resolved.hasCustomChrome && !widget.suppressOverlayBar
        ? mediaQuery.copyWith(
            padding: mediaQuery.padding.copyWith(
              top: math.max(mediaQuery.padding.top, resolved.titleBarHeight),
            ),
            viewPadding: mediaQuery.viewPadding.copyWith(
              top: math.max(
                mediaQuery.viewPadding.top,
                resolved.titleBarHeight,
              ),
            ),
          )
        : mediaQuery;

    _canToggleF11 =
        actions != null &&
        (platform == TargetPlatform.linux ||
            (platform == TargetPlatform.windows &&
                !resolved.usesSystemTitleBar));

    final Widget content = MediaQuery(
      data: adjustedMediaQuery,
      child: DesktopChromeMetrics(
        titleBarHeight: resolved.titleBarHeight,
        leadingInset: resolved.leadingInset,
        trailingInset: resolved.trailingInset,
        trafficLightSize: resolved.trafficLightSize,
        isFullScreen: resolved.isFullScreen,
        isMaximized: resolved.isMaximized,
        isActive: resolved.isActive,
        usesSystemTitleBar: resolved.usesSystemTitleBar,
        showCustomButtons: resolved.showCustomButtons,
        hostMetrics: hostMetrics,
        actions: actions,
        showSimulatedTrafficLights: showSimulatedTrafficLights,
        brightnessListenable: brightnessListenable,
        child: widget.child,
      ),
    );

    final showFullscreenHoverOverlay =
        resolved.isFullScreen &&
        !resolved.usesSystemTitleBar &&
        platform != TargetPlatform.macOS;
    final showLegacyOverlay =
        resolved.hasCustomChrome && !widget.suppressOverlayBar;

    if (!showLegacyOverlay && !showFullscreenHoverOverlay) {
      return content;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        if (showLegacyOverlay)
          ..._buildWindowChromeStripLayers(
            chrome: resolved,
            hostMetrics: hostMetrics,
            platform: platform,
            actions: actions,
            dragKey: _dragKey,
            maximizeKey: _maximizeKey,
            brightnessListenable: brightnessListenable,
            showSimulatedTrafficLights: showSimulatedTrafficLights,
            ignorePointerOnWindowsDrag: false,
            expandDragToLeftWithButtons: false,
          ),
        if (showFullscreenHoverOverlay)
          _FullscreenHoverOverlay(
            revealed: _hoverReveal,
            onHoverChanged: (hovered) {
              if (_hoverReveal != hovered) {
                setState(() => _hoverReveal = hovered);
              }
            },
            actions: actions,
            hostMetrics: hostMetrics,
            brightnessListenable: brightnessListenable,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final env = WindowEnvironmentOverride.maybeOf(context);
    final scope = DesktopWindowScope.maybeOf(context);
    final metricsOverride = widget.metricsOverride ?? env?.desktopMetrics;
    final actions =
        widget.actionsOverride ?? env?.desktopActions ?? scope?.actions;
    final showTrafficLights =
        widget.showSimulatedTrafficLights ||
        (env?.showSimulatedTrafficLights ?? false);
    final brightnessListenable =
        widget.captionBrightnessOverride ??
        DesktopSystemBarsScope.maybeOf(context)?.brightness;

    if (metricsOverride != null) {
      return _buildFrame(
        context,
        metricsOverride,
        actions,
        brightnessListenable,
        showTrafficLights,
      );
    }
    if (scope == null) {
      return _buildFrame(
        context,
        DesktopWindowPlatformMetrics.fallback,
        actions,
        brightnessListenable,
        showTrafficLights,
      );
    }
    return ValueListenableBuilder<DesktopWindowPlatformMetrics>(
      valueListenable: scope.metrics,
      builder: (context, hostMetrics, _) => _buildFrame(
        context,
        hostMetrics,
        actions,
        brightnessListenable,
        showTrafficLights,
      ),
    );
  }
}

/// Shared title-bar overlay layers (drag zone, optional simulated macOS
/// traffic lights, and optional custom minimize/maximize/close buttons) used
/// by both [DesktopWindowFrame]'s legacy overlay and
/// [DesktopFallbackWindowChrome].
List<Widget> _buildWindowChromeStripLayers({
  required DesktopChromeMetrics chrome,
  required DesktopWindowPlatformMetrics? hostMetrics,
  required TargetPlatform platform,
  required DesktopWindowActions? actions,
  required GlobalKey dragKey,
  required GlobalKey maximizeKey,
  GlobalKey? captionButtonsKey,
  required ValueListenable<Brightness>? brightnessListenable,
  required bool showSimulatedTrafficLights,
  required bool ignorePointerOnWindowsDrag,
  required bool expandDragToLeftWithButtons,
}) {
  final dragLeft = expandDragToLeftWithButtons && chrome.showCustomButtons
      ? 0.0
      : chrome.leadingInset;
  final Widget windowsDragChild = ignorePointerOnWindowsDrag
      ? const IgnorePointer(child: SizedBox.expand())
      : const SizedBox.expand();
  final dragZone = Positioned(
    top: 0,
    left: dragLeft,
    right: chrome.trailingInset,
    height: chrome.titleBarHeight,
    child: KeyedSubtree(
      key: dragKey,
      child: platform == TargetPlatform.windows
          ? windowsDragChild
          : GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: actions == null
                  ? null
                  : (_) => actions.onStartDragging(),
              onDoubleTap: actions?.onTitleBarDoubleClick,
              child: const SizedBox.expand(),
            ),
    ),
  );
  final showMacLights =
      platform == TargetPlatform.macOS && showSimulatedTrafficLights;
  final Widget captionButtons = DesktopWindowCaptionButtons(
    height: chrome.titleBarHeight,
    isMaximized: chrome.isMaximized,
    isActive: chrome.isActive,
    nativeHoveredButton: hostMetrics?.hoveredButton ?? '',
    nativePressedButton: hostMetrics?.pressedButton ?? '',
    maximizeKey: maximizeKey,
    actions: actions,
    brightnessListenable: brightnessListenable,
  );
  return [
    dragZone,
    if (showMacLights)
      PositionedDirectional(
        top: 0,
        start: 0,
        width: chrome.leadingInset > 0
            ? chrome.leadingInset
            : _macFallbackTrafficLightWidth,
        height: chrome.titleBarHeight,
        child: SimulatedMacTrafficLights(height: chrome.titleBarHeight),
      ),
    if (chrome.showCustomButtons)
      Positioned(
        top: 0,
        right: 0,
        height: chrome.titleBarHeight,
        child: captionButtonsKey == null
            ? captionButtons
            : KeyedSubtree(key: captionButtonsKey, child: captionButtons),
      ),
  ];
}

class _FullscreenHoverOverlay extends StatelessWidget {
  const _FullscreenHoverOverlay({
    required this.revealed,
    required this.onHoverChanged,
    required this.actions,
    required this.hostMetrics,
    required this.brightnessListenable,
  });

  final bool revealed;
  final ValueChanged<bool> onHoverChanged;
  final DesktopWindowActions? actions;
  final DesktopWindowPlatformMetrics hostMetrics;
  final ValueListenable<Brightness>? brightnessListenable;

  @override
  Widget build(BuildContext context) {
    final duration = MotionTokens.resolve(context, MotionTokens.chrome);
    final surface = Theme.of(context).colorScheme.surface;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: MouseRegion(
        onEnter: (_) => onHoverChanged(true),
        onExit: (_) => onHoverChanged(false),
        child: SizedBox(
          height: revealed ? FuncSpacing.xxl : FuncSpacing.sm,
          child: IgnorePointer(
            ignoring: !revealed,
            child: AnimatedOpacity(
              opacity: revealed ? 1 : 0,
              duration: duration,
              curve: MotionTokens.chromeCurve,
              child: Align(
                alignment: Alignment.topRight,
                child: Material(
                  color: surface.withValues(alpha: 0.92),
                  elevation: 2,
                  child: DesktopWindowCaptionButtons(
                    height: FuncSpacing.xxl,
                    isMaximized: true,
                    isActive: hostMetrics.isActive,
                    nativeHoveredButton: '',
                    nativePressedButton: '',
                    maximizeKey: null,
                    actions: actions == null
                        ? null
                        : DesktopWindowActions(
                            onMinimize: actions!.onMinimize,
                            onToggleMaximize: actions!.onToggleFullScreen,
                            onClose: actions!.onClose,
                            onToggleFullScreen: actions!.onToggleFullScreen,
                            onStartDragging: actions!.onStartDragging,
                            onTitleBarDoubleClick:
                                actions!.onTitleBarDoubleClick,
                            onRegionsChanged: actions!.onRegionsChanged,
                          ),
                    brightnessListenable: brightnessListenable,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating window chrome (caption drag zone, native/simulated traffic lights,
/// and custom minimize/maximize/close buttons) mounted when `DesktopCommandBar`
/// hides itself on desktop (e.g. inside `ImageViewerPage`).
class DesktopFallbackWindowChrome extends StatefulWidget {
  const DesktopFallbackWindowChrome({
    super.key,
    this.enabled = true,
    required this.chrome,
    required this.child,
  });

  final bool enabled;
  final DesktopChromeMetrics chrome;
  final Widget child;

  @override
  State<DesktopFallbackWindowChrome> createState() =>
      _DesktopFallbackWindowChromeState();
}

class _DesktopFallbackWindowChromeState
    extends State<DesktopFallbackWindowChrome> {
  final GlobalKey _dragKey = GlobalKey();
  final GlobalKey _maximizeKey = GlobalKey();
  final GlobalKey _captionButtonsKey = GlobalKey();
  final DesktopTitleBarRegionPublisher _regionPublisher =
      DesktopTitleBarRegionPublisher();

  DesktopChromeMetrics? _lastChrome;

  bool get _isActive => widget.enabled && widget.chrome.hasCustomChrome;

  @override
  void didUpdateWidget(DesktopFallbackWindowChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    _lastChrome = widget.chrome;
    if (!_isActive) {
      _regionPublisher.clear(_lastChrome?.actions);
    }
  }

  @override
  void dispose() {
    _regionPublisher.clear(_lastChrome?.actions);
    super.dispose();
  }

  void _scheduleRegionPublish(DesktopChromeMetrics chrome) {
    _lastChrome = chrome;
    _regionPublisher.schedulePublish(
      chrome.actions,
      isMounted: () => mounted && _isActive,
      resolve: () {
        final currentChrome = _lastChrome;
        final currentActions = currentChrome?.actions;
        if (currentActions == null || currentChrome == null) return null;
        final regions = <DesktopTitleBarRegion>[];
        if (currentChrome.hasCustomChrome) {
          DesktopTitleBarRegionPublisher.addRegion(
            regions,
            _dragKey,
            'caption',
          );
          if (currentChrome.showCustomButtons) {
            DesktopTitleBarRegionPublisher.addRegion(
              regions,
              _maximizeKey,
              'maximize',
            );
            DesktopTitleBarRegionPublisher.addRegion(
              regions,
              _captionButtonsKey,
              'buttons',
            );
          }
        }
        return (
          actions: currentActions,
          regions: regions,
          titleBarHeight: currentChrome.hasCustomChrome
              ? currentChrome.titleBarHeight
              : null,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final chrome = widget.chrome;
    _lastChrome = chrome;
    if (!widget.enabled || !chrome.hasCustomChrome) {
      _regionPublisher.clear(chrome.actions);
      return DesktopFallbackChromeStack(
        hasDragZone: false,
        children: [widget.child],
      );
    }
    _scheduleRegionPublish(chrome);
    final platform = Theme.of(context).platform;
    return DesktopFallbackChromeStack(
      hasDragZone: true,
      children: [
        widget.child,
        ..._buildWindowChromeStripLayers(
          chrome: chrome,
          hostMetrics: chrome.hostMetrics,
          platform: platform,
          actions: chrome.actions,
          dragKey: _dragKey,
          maximizeKey: _maximizeKey,
          captionButtonsKey: _captionButtonsKey,
          brightnessListenable: chrome.brightnessListenable,
          showSimulatedTrafficLights: chrome.showSimulatedTrafficLights,
          ignorePointerOnWindowsDrag: true,
          expandDragToLeftWithButtons: true,
        ),
      ],
    );
  }
}
