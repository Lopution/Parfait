import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';

import '../../core/platform/desktop_window_channel.dart';
import '../../core/platform/platform_caps.dart';
import '../window/desktop_title_bar.dart';
import 'app_breakpoints.dart';
import 'input_modality.dart';

/// Material 3 window width tier independent of platform or input modality.
enum WindowWidthClass { compact, medium, expanded, large, extraLarge }

/// Physical or virtual hinge/fold posture across the viewport.
enum FoldPosture { flat, book, tabletop }

/// Ephemeral host environment overrides (simulated shell, headless review).
///
/// Sits above [AppChrome] so platform chrome, display size, and desktop
/// title-bar metrics can hot-swap without resetting routes, providers, or
/// image worker state.
class WindowEnvironmentOverride extends InheritedWidget {
  const WindowEnvironmentOverride({
    super.key,
    this.displaySize,
    this.targetPlatform,
    this.platformCaps,
    this.desktopMetrics,
    this.desktopActions,
    this.showSimulatedTrafficLights = false,
    required super.child,
  });

  final Size? displaySize;
  final TargetPlatform? targetPlatform;
  final PlatformCaps? platformCaps;
  final DesktopWindowPlatformMetrics? desktopMetrics;
  final DesktopWindowActions? desktopActions;
  final bool showSimulatedTrafficLights;

  static WindowEnvironmentOverride? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WindowEnvironmentOverride>();

  @override
  bool updateShouldNotify(WindowEnvironmentOverride oldWidget) =>
      displaySize != oldWidget.displaySize ||
      targetPlatform != oldWidget.targetPlatform ||
      platformCaps != oldWidget.platformCaps ||
      desktopMetrics != oldWidget.desktopMetrics ||
      desktopActions != oldWidget.desktopActions ||
      showSimulatedTrafficLights != oldWidget.showSimulatedTrafficLights;
}

/// Four-dimensional orthogonal layout specification:
///
/// 1. Spatial size & width tier ([windowSize], [widthClass])
/// 2. Physical hinge / fold posture ([posture], [hingeBounds])
/// 3. Interaction modality ([inputModality])
/// 4. Host platform conventions & display density ([targetPlatform], [platformCaps], [devicePixelRatio])
@immutable
class WindowLayoutSpec {
  const WindowLayoutSpec({
    required this.windowSize,
    required this.widthClass,
    required this.posture,
    required this.hingeBounds,
    required this.safePadding,
    required this.devicePixelRatio,
    required this.inputModality,
    required this.targetPlatform,
    required this.platformCaps,
  });

  /// Minimum height left for each pane to accept a horizontal tabletop split.
  static const double minTabletopPaneHeight = 180;

  final Size windowSize;
  final WindowWidthClass widthClass;
  final FoldPosture posture;
  final Rect? hingeBounds;
  final EdgeInsets safePadding;
  final double devicePixelRatio;
  final InputModality inputModality;
  final TargetPlatform targetPlatform;
  final PlatformCaps platformCaps;

  bool get isHingeVertical => posture == FoldPosture.book;
  bool get isHingeHorizontal => posture == FoldPosture.tabletop;

  static WindowWidthClass widthClassFor(double width) {
    if (width >= AppBreakpoints.extraLarge) return WindowWidthClass.extraLarge;
    if (width >= AppBreakpoints.large) return WindowWidthClass.large;
    if (width >= AppBreakpoints.expanded) return WindowWidthClass.expanded;
    if (width >= AppBreakpoints.medium) return WindowWidthClass.medium;
    return WindowWidthClass.compact;
  }

  /// Resolves [FoldPosture] and logical hinge bounds from engine display features.
  ///
  /// Engine [ui.DisplayFeature.bounds] arrive in logical pixels already; do not
  /// divide by DPR.
  static (FoldPosture, Rect?) resolveFold(
    Size windowSize,
    Iterable<ui.DisplayFeature> features,
  ) {
    for (final feature in features) {
      final bounds = feature.bounds;
      final isFoldOrHinge =
          feature.type == ui.DisplayFeatureType.hinge ||
          feature.type == ui.DisplayFeatureType.fold;
      if (!isFoldOrHinge) continue;
      if (bounds.width <= 0 && bounds.height <= 0) continue;

      final isVertical = bounds.height > bounds.width;
      final isHorizontal = bounds.width > bounds.height;

      if (isVertical) {
        final active =
            feature.type == ui.DisplayFeatureType.hinge ||
            feature.state == ui.DisplayFeatureState.postureHalfOpened;
        if (active && windowSize.width >= AppBreakpoints.medium) {
          return (FoldPosture.book, bounds);
        }
        continue;
      }

      if (isHorizontal) {
        final halfOpened =
            feature.state == ui.DisplayFeatureState.postureHalfOpened ||
            (feature.type == ui.DisplayFeatureType.hinge &&
                bounds.height > 0 &&
                feature.state != ui.DisplayFeatureState.postureFlat);
        final topAvailable = bounds.top;
        final bottomAvailable = windowSize.height - bounds.bottom;
        if (halfOpened &&
            topAvailable >= minTabletopPaneHeight &&
            bottomAvailable >= minTabletopPaneHeight) {
          return (FoldPosture.tabletop, bounds);
        }
      }
    }
    return (FoldPosture.flat, null);
  }

  /// Computes a [WindowLayoutSpec] from an explicit [MediaQueryData].
  factory WindowLayoutSpec.fromMediaQuery(
    MediaQueryData data, {
    InputModality? inputModality,
    TargetPlatform? targetPlatform,
    PlatformCaps? platformCaps,
  }) {
    final resolvedPlatform = targetPlatform ?? defaultTargetPlatform;
    final (posture, hingeBounds) = resolveFold(data.size, data.displayFeatures);
    return WindowLayoutSpec(
      windowSize: data.size,
      widthClass: widthClassFor(data.size.width),
      posture: posture,
      hingeBounds: hingeBounds,
      safePadding: data.padding,
      devicePixelRatio: data.devicePixelRatio,
      inputModality: inputModality ?? defaultInputModalityFor(resolvedPlatform),
      targetPlatform: resolvedPlatform,
      platformCaps: platformCaps ?? PlatformCaps.system(),
    );
  }

  /// Resolves only the ambient [FoldPosture] without subscribing to theme or modality.
  static FoldPosture postureOf(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final features = MediaQuery.displayFeaturesOf(context);
    return resolveFold(size, features).$1;
  }

  /// Resolves and subscribes to the full four-dimensional [WindowLayoutSpec].
  static WindowLayoutSpec of(BuildContext context) {
    final media = MediaQuery.of(context);
    final env = WindowEnvironmentOverride.maybeOf(context);
    final platform = env?.targetPlatform ?? Theme.of(context).platform;
    final modality =
        InputModalityScope.maybeOf(context) ??
        defaultInputModalityFor(platform);
    final caps = env?.platformCaps ?? PlatformCaps.system();
    return WindowLayoutSpec.fromMediaQuery(
      media,
      inputModality: modality,
      targetPlatform: platform,
      platformCaps: caps,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowLayoutSpec &&
          other.windowSize == windowSize &&
          other.widthClass == widthClass &&
          other.posture == posture &&
          other.hingeBounds == hingeBounds &&
          other.safePadding == safePadding &&
          other.devicePixelRatio == devicePixelRatio &&
          other.inputModality == inputModality &&
          other.targetPlatform == targetPlatform &&
          other.platformCaps.isAndroid == platformCaps.isAndroid &&
          other.platformCaps.isIOS == platformCaps.isIOS &&
          other.platformCaps.isWindows == platformCaps.isWindows &&
          other.platformCaps.isMacOS == platformCaps.isMacOS &&
          other.platformCaps.isLinux == platformCaps.isLinux;

  @override
  int get hashCode => Object.hash(
    windowSize,
    widthClass,
    posture,
    hingeBounds,
    safePadding,
    devicePixelRatio,
    inputModality,
    targetPlatform,
    platformCaps.isAndroid,
    platformCaps.isIOS,
    platformCaps.isWindows,
    platformCaps.isMacOS,
    platformCaps.isLinux,
  );
}
