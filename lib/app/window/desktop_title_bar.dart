import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform/desktop_window_channel.dart';
import '../../l10n/context.dart';
import '../motion/motion_tokens.dart';
import '../system_ui.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';

const double _windowsButtonWidth = 46;
const double _windowsControlsWidth = _windowsButtonWidth * 3;
const double _macFallbackTrafficLightWidth = 78;
const Color _closeHoverBackground = Color(0xFFC42B1C);

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
  });

  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;
  final VoidCallback onToggleFullScreen;
  final VoidCallback onStartDragging;
  final VoidCallback onTitleBarDoubleClick;
  final ValueChanged<List<DesktopTitleBarRegion>> onRegionsChanged;
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
/// Published above the router so [ShellRail], [AppTopBar], and immersive pages
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
      showCustomButtons = false;

  final double titleBarHeight;
  final double leadingInset;
  final double trailingInset;
  final Size trafficLightSize;
  final bool isFullScreen;
  final bool isMaximized;
  final bool isActive;
  final bool usesSystemTitleBar;
  final bool showCustomButtons;

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
      showCustomButtons != oldWidget.showCustomButtons;
}

/// Top-level frameless desktop chrome shell wrapping the router.
class DesktopWindowFrame extends StatefulWidget {
  const DesktopWindowFrame({
    super.key,
    required this.child,
    this.metricsOverride,
    this.actionsOverride,
    this.captionBrightnessOverride,
  });

  final Widget child;
  final DesktopWindowPlatformMetrics? metricsOverride;
  final DesktopWindowActions? actionsOverride;
  final ValueListenable<Brightness>? captionBrightnessOverride;

  @override
  State<DesktopWindowFrame> createState() => _DesktopWindowFrameState();
}

class _DesktopWindowFrameState extends State<DesktopWindowFrame> {
  final GlobalKey _dragKey = GlobalKey();
  final GlobalKey _maximizeKey = GlobalKey();

  bool _hoverReveal = false;
  bool _regionMeasurePending = false;
  bool _canToggleF11 = false;
  String? _lastRegionSignature;
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
    if (actions == null || _regionMeasurePending) return;
    _regionMeasurePending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _regionMeasurePending = false;
      if (!mounted) return;
      final currentActions = _lastActions;
      final currentChrome = _lastChrome;
      if (currentActions == null || currentChrome == null) return;
      final regions = <DesktopTitleBarRegion>[];
      if (currentChrome.hasCustomChrome) {
        final dragRect = _globalRectOf(_dragKey);
        if (dragRect != null && !dragRect.isEmpty) {
          regions.add(DesktopTitleBarRegion(rect: dragRect, kind: 'caption'));
        }
        if (currentChrome.showCustomButtons) {
          final maxRect = _globalRectOf(_maximizeKey);
          if (maxRect != null && !maxRect.isEmpty) {
            regions.add(DesktopTitleBarRegion(rect: maxRect, kind: 'maximize'));
          }
        }
      }
      final signature = [
        for (final r in regions)
          '${r.kind}:${r.rect.left.toStringAsFixed(1)},'
              '${r.rect.top.toStringAsFixed(1)},'
              '${r.rect.right.toStringAsFixed(1)},'
              '${r.rect.bottom.toStringAsFixed(1)}',
      ].join(';');
      if (signature == _lastRegionSignature) return;
      _lastRegionSignature = signature;
      currentActions.onRegionsChanged(regions);
    });
  }

  Rect? _globalRectOf(GlobalKey key) {
    final renderObject = key.currentContext?.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  Widget _buildFrame(
    BuildContext context,
    DesktopWindowPlatformMetrics hostMetrics,
    DesktopWindowActions? actions,
    ValueListenable<Brightness>? brightnessListenable,
  ) {
    final platform = Theme.of(context).platform;
    final resolved = DesktopChromeMetrics.resolveData(
      platform: platform,
      hostMetrics: hostMetrics,
      child: widget.child,
    );
    _scheduleRegionPublish(actions, resolved);

    final mediaQuery = MediaQuery.of(context);
    final adjustedMediaQuery = resolved.hasCustomChrome
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

    final canToggleF11 =
        actions != null &&
        !resolved.usesSystemTitleBar &&
        (platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux);
    _canToggleF11 = canToggleF11;

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
        child: widget.child,
      ),
    );

    final showFullscreenHoverOverlay =
        resolved.isFullScreen &&
        !resolved.usesSystemTitleBar &&
        platform != TargetPlatform.macOS;

    if (!resolved.hasCustomChrome && !showFullscreenHoverOverlay) {
      return content;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        if (resolved.hasCustomChrome)
          _IntegratedTitleBarOverlay(
            chrome: resolved,
            hostMetrics: hostMetrics,
            platform: platform,
            actions: actions,
            dragKey: _dragKey,
            maximizeKey: _maximizeKey,
            brightnessListenable: brightnessListenable,
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
    final scope = DesktopWindowScope.maybeOf(context);
    final actions = widget.actionsOverride ?? scope?.actions;
    final brightnessListenable =
        widget.captionBrightnessOverride ??
        DesktopSystemBarsScope.maybeOf(context)?.brightness;

    if (widget.metricsOverride != null) {
      return _buildFrame(
        context,
        widget.metricsOverride!,
        actions,
        brightnessListenable,
      );
    }

    if (scope == null) {
      return _buildFrame(
        context,
        DesktopWindowPlatformMetrics.fallback,
        actions,
        brightnessListenable,
      );
    }

    return ValueListenableBuilder<DesktopWindowPlatformMetrics>(
      valueListenable: scope.metrics,
      builder: (context, hostMetrics, _) =>
          _buildFrame(context, hostMetrics, actions, brightnessListenable),
    );
  }
}

class _IntegratedTitleBarOverlay extends StatelessWidget {
  const _IntegratedTitleBarOverlay({
    required this.chrome,
    required this.hostMetrics,
    required this.platform,
    required this.actions,
    required this.dragKey,
    required this.maximizeKey,
    required this.brightnessListenable,
  });

  final DesktopChromeMetrics chrome;
  final DesktopWindowPlatformMetrics hostMetrics;
  final TargetPlatform platform;
  final DesktopWindowActions? actions;
  final GlobalKey dragKey;
  final GlobalKey maximizeKey;
  final ValueListenable<Brightness>? brightnessListenable;

  @override
  Widget build(BuildContext context) {
    final dragZone = Positioned(
      top: 0,
      left: chrome.leadingInset,
      right: chrome.trailingInset,
      height: chrome.titleBarHeight,
      child: KeyedSubtree(
        key: dragKey,
        child: platform == TargetPlatform.windows
            ? const SizedBox.expand()
            : GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: actions == null
                    ? null
                    : (_) => actions!.onStartDragging(),
                onDoubleTap: actions?.onTitleBarDoubleClick,
                child: const SizedBox.expand(),
              ),
      ),
    );

    if (!chrome.showCustomButtons) {
      return dragZone;
    }

    return Stack(
      children: [
        dragZone,
        Positioned(
          top: 0,
          right: 0,
          height: chrome.titleBarHeight,
          child: _CaptionButtonsCluster(
            height: chrome.titleBarHeight,
            isMaximized: chrome.isMaximized,
            isActive: chrome.isActive,
            nativeHoveredButton: hostMetrics.hoveredButton,
            nativePressedButton: hostMetrics.pressedButton,
            maximizeKey: maximizeKey,
            actions: actions,
            brightnessListenable: brightnessListenable,
          ),
        ),
      ],
    );
  }
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
                  child: _CaptionButtonsCluster(
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

class _CaptionButtonsCluster extends StatelessWidget {
  const _CaptionButtonsCluster({
    required this.height,
    required this.isMaximized,
    required this.isActive,
    required this.nativeHoveredButton,
    required this.nativePressedButton,
    required this.maximizeKey,
    required this.actions,
    required this.brightnessListenable,
  });

  final double height;
  final bool isMaximized;
  final bool isActive;
  final String nativeHoveredButton;
  final String nativePressedButton;
  final GlobalKey? maximizeKey;
  final DesktopWindowActions? actions;
  final ValueListenable<Brightness>? brightnessListenable;

  Widget _cluster(BuildContext context, Brightness surfaceBrightness) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final iconBase = surfaceBrightness == Brightness.dark
        ? FuncTokens.white
        : theme.colorScheme.onSurface;
    final foreground = isActive ? iconBase : iconBase.withValues(alpha: 0.6);
    final hoverOverlay = surfaceBrightness == Brightness.dark
        ? FuncTokens.white.withValues(alpha: 0.10)
        : theme.colorScheme.onSurface.withValues(alpha: 0.08);
    final pressedOverlay = surfaceBrightness == Brightness.dark
        ? FuncTokens.white.withValues(alpha: 0.16)
        : theme.colorScheme.onSurface.withValues(alpha: 0.14);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowCaptionButton(
          key: const Key('desktop-window-minimize'),
          tooltip: l10n.windowMinimize,
          height: height,
          kind: _CaptionButtonKind.minimize,
          foreground: foreground,
          hoverColor: hoverOverlay,
          pressedColor: pressedOverlay,
          onPressed: actions?.onMinimize,
        ),
        KeyedSubtree(
          key: maximizeKey,
          child: _WindowCaptionButton(
            key: const Key('desktop-window-maximize'),
            tooltip: isMaximized ? l10n.windowRestore : l10n.windowMaximize,
            height: height,
            kind: isMaximized
                ? _CaptionButtonKind.restore
                : _CaptionButtonKind.maximize,
            foreground: foreground,
            hoverColor: hoverOverlay,
            pressedColor: pressedOverlay,
            forceHovered: nativeHoveredButton == 'maximize',
            forcePressed: nativePressedButton == 'maximize',
            onPressed: actions?.onToggleMaximize,
          ),
        ),
        _WindowCaptionButton(
          key: const Key('desktop-window-close'),
          tooltip: l10n.windowClose,
          height: height,
          kind: _CaptionButtonKind.close,
          foreground: foreground,
          hoverColor: _closeHoverBackground,
          hoverForeground: FuncTokens.white,
          pressedColor: _closeHoverBackground.withValues(alpha: 0.85),
          onPressed: actions?.onClose,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final listenable = brightnessListenable;
    if (listenable == null) {
      return _cluster(context, Theme.of(context).brightness);
    }
    return ValueListenableBuilder<Brightness>(
      valueListenable: listenable,
      builder: (context, brightness, _) => _cluster(context, brightness),
    );
  }
}

enum _CaptionButtonKind { minimize, maximize, restore, close }

class _WindowCaptionButton extends StatefulWidget {
  const _WindowCaptionButton({
    super.key,
    required this.tooltip,
    required this.height,
    required this.kind,
    required this.foreground,
    required this.hoverColor,
    required this.pressedColor,
    this.hoverForeground,
    this.forceHovered = false,
    this.forcePressed = false,
    this.onPressed,
  });

  final String tooltip;
  final double height;
  final _CaptionButtonKind kind;
  final Color foreground;
  final Color hoverColor;
  final Color pressedColor;
  final Color? hoverForeground;
  final bool forceHovered;
  final bool forcePressed;
  final VoidCallback? onPressed;

  @override
  State<_WindowCaptionButton> createState() => _WindowCaptionButtonState();
}

class _WindowCaptionButtonState extends State<_WindowCaptionButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final effectivePressed = _pressed || widget.forcePressed;
    final effectiveHovered = _hovered || widget.forceHovered;
    final bg = effectivePressed
        ? widget.pressedColor
        : effectiveHovered
        ? widget.hoverColor
        : FuncTokens.transparent;
    final fg = (effectiveHovered || effectivePressed)
        ? (widget.hoverForeground ?? widget.foreground)
        : widget.foreground;

    return Semantics(
      button: true,
      label: widget.tooltip,
      child: Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: widget.onPressed,
            child: ColoredBox(
              color: bg,
              child: SizedBox(
                width: _windowsButtonWidth,
                height: widget.height,
                child: Center(
                  child: CustomPaint(
                    size: const Size.square(10),
                    painter: _CaptionGlyphPainter(kind: widget.kind, color: fg),
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

class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter({required this.kind, required this.color});

  final _CaptionButtonKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    final w = size.width;
    final h = size.height;

    switch (kind) {
      case _CaptionButtonKind.minimize:
        final y = (h / 2).floorToDouble() + 0.5;
        canvas.drawLine(Offset(0, y), Offset(w, y), paint);
      case _CaptionButtonKind.maximize:
        canvas.drawRect(Rect.fromLTWH(0.5, 0.5, w - 1, h - 1), paint);
      case _CaptionButtonKind.restore:
        // Front box (bottom-left) + overlapping back frame top/right edges.
        const inset = 2.0;
        canvas.drawRect(
          Rect.fromLTWH(0.5, inset + 0.5, w - inset - 1, h - inset - 1),
          paint,
        );
        final back = Path()
          ..moveTo(inset + 0.5, inset + 0.5)
          ..lineTo(inset + 0.5, 0.5)
          ..lineTo(w - 0.5, 0.5)
          ..lineTo(w - 0.5, h - inset - 0.5)
          ..lineTo(w - inset - 0.5, h - inset - 0.5);
        canvas.drawPath(back, paint);
      case _CaptionButtonKind.close:
        canvas.drawLine(
          const Offset(0.5, 0.5),
          Offset(w - 0.5, h - 0.5),
          paint,
        );
        canvas.drawLine(Offset(w - 0.5, 0.5), Offset(0.5, h - 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(_CaptionGlyphPainter oldDelegate) =>
      kind != oldDelegate.kind || color != oldDelegate.color;
}
