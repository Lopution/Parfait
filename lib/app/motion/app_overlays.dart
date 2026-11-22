import 'dart:math' as math;
import 'dart:ui' as ui show DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show HitTestResult, PointerUpEvent;
import 'package:material_ui/material_ui.dart';
import 'package:smooth_sheets/smooth_sheets.dart';

import '../../core/debug/frame_probe.dart';
import '../layout/app_breakpoints.dart';
import '../layout/form_factor.dart';
import '../layout/input_modality.dart';
import '../theme/func_semantic_tokens.dart';
import '../widgets/app_date_picker.dart';
import '../widgets/prompt_host.dart';
import '../window/desktop_command_bar_scope.dart'
    show DesktopCommandBarScope, desktopCommandBarHeightFor;
import '../window/desktop_title_bar.dart' show DesktopChromeMetrics;
import 'motion_tokens.dart';

/// Whether secondary overlays should use bounded container presentations
/// (centered dialog or side sheet) rather than full-width bottom sheets.
///
/// Requires at least medium width (600dp) and non-compact height (480dp)
/// so touch tablets and desktop windows gain bounded dialogs and side
/// sheets while turned phones (`isPhoneLandscape`) keep bottom sheets.
bool useWideOverlay(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width >= AppBreakpoints.medium &&
      size.height >= AppBreakpoints.compactHeight;
}

/// Whether secondary overlays should use pointer-anchored presentations
/// (popovers) rather than centered modals or bottom sheets.
bool usePointerOverlay(BuildContext context) {
  final modality =
      InputModalityScope.maybeOf(context) ??
      defaultInputModalityFor(Theme.of(context).platform);
  return modality == InputModality.pointer && useWideOverlay(context);
}

/// Alias of [usePointerOverlay] preserved for callers checking pointer-driven
/// desktop overlays.
bool useDesktopOverlay(BuildContext context) => usePointerOverlay(context);

Widget _clampingScroll(BuildContext context, Widget child) =>
    ScrollConfiguration(
      behavior: ScrollConfiguration.of(
        context,
      ).copyWith(physics: const ClampingScrollPhysics()),
      child: child,
    );

Widget _transparentSheetDecoration(BuildContext _, Widget child) =>
    Material(type: MaterialType.transparency, child: child);

/// Shared modal bottom sheet surface powered by `smooth_sheets`' [Sheet].
class AppBottomSheet extends StatelessWidget {
  const AppBottomSheet({
    super.key,
    required this.builder,
    this.backgroundColor,
    this.isScrollControlled = false,
    this.showDragHandle = false,
  });

  final WidgetBuilder builder;
  final Color? backgroundColor;
  final bool isScrollControlled;
  final bool showDragHandle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sheetTheme = theme.bottomSheetTheme;
    final resolvedBg =
        backgroundColor ??
        sheetTheme.modalBackgroundColor ??
        sheetTheme.backgroundColor ??
        theme.colorScheme.surfaceContainer;
    final decoration = resolvedBg.a == 0
        ? const SheetDecorationBuilder(
            size: SheetSize.fit,
            builder: _transparentSheetDecoration,
          )
        : MaterialSheetDecoration(
            size: SheetSize.fit,
            color: resolvedBg,
            shadowColor: sheetTheme.shadowColor ?? theme.colorScheme.shadow,
            elevation: sheetTheme.modalElevation ?? 6,
            shape:
                sheetTheme.shape ??
                RoundedRectangleBorder(
                  borderRadius: FuncShape.sheet,
                  side: _overlayBorder(context),
                ),
            clipBehavior: Clip.antiAlias,
          );

    Widget content = _clampingScroll(context, builder(context));
    if (showDragHandle) {
      final handleColor =
          sheetTheme.dragHandleColor ??
          theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4);
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              top: FuncSpacing.md,
              bottom: FuncSpacing.xs,
            ),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: handleColor,
                  borderRadius: FuncShape.pill,
                ),
                child: const SizedBox(width: 32, height: 4),
              ),
            ),
          ),
          Flexible(child: content),
        ],
      );
    }
    if (!isScrollControlled) {
      content = ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 9 / 16,
        ),
        child: content,
      );
    }

    return Sheet(
      initialOffset: const SheetOffset(1),
      snapGrid: const SheetSnapGrid.single(snap: SheetOffset(1)),
      scrollConfiguration: const SheetScrollConfiguration(
        scrollSyncMode: SheetScrollHandlingBehavior.always,
      ),
      physics: MotionTokens.enabled(context)
          ? const BouncingSheetPhysics(bounceExtent: 48, resistance: 6)
          : const ClampingSheetPhysics(),
      decoration: decoration,
      child: content,
    );
  }
}

/// App-wide modal bottom sheet entry: one presentation spring and one
/// reduced-motion gate for every sheet. Under reduced motion the sheet
/// snaps open with [ClampingSheetPhysics] and zero duration — the state change
/// still lands, only the slide and bounce are removed.
///
/// The scrim closes the sheet when a touch outside it is released there —
/// a drag counts, not just a tap (see [_ReleaseDismissBarrier]).
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool showDragHandle = false,
  bool useRootNavigator = false,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final localizations = MaterialLocalizations.of(context);
  final (enterDuration, enterCurve) = MotionTokens.springCurve(
    context,
    MotionSpring.spatialDefault,
  );
  final exitDuration = enterDuration == Duration.zero
      ? Duration.zero
      : MotionTokens.resolve(context, MotionTokens.sheetExit);
  return navigator.push(
    _AppBottomSheetRoute<T>(
      builder: builder,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      isScrollControlled: isScrollControlled,
      barrierLabel: localizations.scrimLabel,
      barrierOnTapHint: localizations.scrimOnTapHint(
        localizations.bottomSheetLabel,
      ),
      backgroundColor: backgroundColor,
      modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
      showDragHandle: showDragHandle,
      useSafeArea: useSafeArea,
      enterDuration: enterDuration,
      exitDuration: exitDuration,
      enterCurve: enterCurve,
    ),
  );
}

bool _resolveUseRootNavigator(BuildContext context, bool? useRootNavigator) =>
    useRootNavigator ??
    FormFactor.of(context).hasRail(MediaQuery.sizeOf(context).width);

/// On foldable book postures with a vertical full-height hinge and a side
/// `ShellRail`, anchors dialogs in the sub-screen opposite the rail so the
/// dialog never overlaps the start-side navigation rail.
Offset? _railClearDialogAnchorPoint(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  if (!FormFactor.of(context).hasRail(size.width)) return null;
  final features = MediaQuery.displayFeaturesOf(context);
  if (features.isEmpty) return null;
  final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
  for (final feature in features) {
    final isHinge =
        feature.type == ui.DisplayFeatureType.hinge ||
        feature.type == ui.DisplayFeatureType.fold;
    if (!isHinge) continue;
    final obstructs =
        feature.bounds.shortestSide > 0 ||
        feature.state == ui.DisplayFeatureState.postureHalfOpened;
    if (!obstructs) continue;
    final bounds = feature.bounds;
    final fullHeight = bounds.top <= 1 && bounds.bottom >= size.height - 1;
    if (!fullHeight || bounds.left <= 0 || bounds.right >= size.width) {
      continue;
    }
    final centerX = rtl ? bounds.left / 2 : (bounds.right + size.width) / 2;
    return Offset(centerX, size.height / 2);
  }
  return null;
}

double _desktopCommandBarTopClearance(
  BuildContext context,
  NavigatorState navigator,
) {
  if (!DesktopCommandBarScope.isActiveOf(context)) return 0;
  final chrome = DesktopChromeMetrics.maybeOf(context);
  if (chrome?.isFullScreen ?? false) return 0;
  final commandBar = DesktopCommandBarScope.controllerOf(context);
  if (commandBar != null && commandBar.hidden.value) return 0;
  final overlayRo = navigator.overlay?.context.findRenderObject();
  final overlayTop = overlayRo is RenderBox && overlayRo.hasSize
      ? overlayRo.localToGlobal(Offset.zero).dy
      : 0.0;
  return math.max(0.0, desktopCommandBarHeightFor(chrome) - overlayTop);
}

BorderSide _overlayBorder(BuildContext context) {
  final theme = Theme.of(context);
  final hairline =
      theme.extension<FuncSemanticTokens>()?.brandHairline ??
      theme.colorScheme.outlineVariant;
  return BorderSide(color: hairline);
}

Widget _withTopClearance(double topClearance, Widget child) => topClearance > 0
    ? Padding(
        padding: EdgeInsets.only(top: topClearance),
        child: child,
      )
    : child;

/// Adaptive dialog: renders a centered bounded modal dialog when
/// [useWideOverlay] holds, falling back to [showAppBottomSheet] on compact
/// viewports.
Future<T?> showAppAdaptiveDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxWidth = 520,
  double maxHeightFactor = 0.85,
  EdgeInsets insetPadding = const EdgeInsets.symmetric(
    horizontal: FuncSpacing.xl,
    vertical: FuncSpacing.xl,
  ),
  Color? backgroundColor,
  bool isScrollControlled = true,
  bool useSafeArea = true,
  bool showDragHandle = false,
  bool barrierDismissible = true,
  String? barrierLabel,
  bool? useRootNavigator,
  Offset? anchorPoint,
}) {
  final resolvedUseRootNavigator = _resolveUseRootNavigator(
    context,
    useRootNavigator,
  );
  if (!useWideOverlay(context)) {
    return showAppBottomSheet<T>(
      context: context,
      builder: builder,
      backgroundColor: backgroundColor,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: showDragHandle,
      useRootNavigator: resolvedUseRootNavigator,
    );
  }
  final navigator = Navigator.of(
    context,
    rootNavigator: resolvedUseRootNavigator,
  );
  final topClearance = _desktopCommandBarTopClearance(context, navigator);
  final resolvedAnchorPoint =
      anchorPoint ?? _railClearDialogAnchorPoint(context);
  final theme = Theme.of(context);
  final surfaceColor =
      backgroundColor ??
      theme.bottomSheetTheme.backgroundColor ??
      theme.colorScheme.surfaceContainerHigh;
  return navigator.push(
    _AppDialogRoute<T>(
      context: context,
      topClearance: topClearance,
      anchorPoint: resolvedAnchorPoint,
      builder: (routeContext) {
        final window = MediaQuery.sizeOf(routeContext);
        final keyboardInset = MediaQuery.viewInsetsOf(routeContext).bottom;
        final boundedMaxWidth = math.min(
          maxWidth,
          math.min(window.width * 0.72, 640.0),
        );
        return Padding(
          padding: EdgeInsets.only(top: topClearance, bottom: keyboardInset),
          child: Center(
            child: Padding(
              padding: insetPadding,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: boundedMaxWidth,
                  maxHeight: window.height * maxHeightFactor,
                ),
                child: Material(
                  color: surfaceColor,
                  surfaceTintColor: Colors.transparent,
                  elevation: 6,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: FuncShape.dialog,
                    side: _overlayBorder(routeContext),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: MediaQuery.removePadding(
                    context: routeContext,
                    removeTop: true,
                    removeBottom: true,
                    removeLeft: true,
                    removeRight: true,
                    child: _clampingScroll(routeContext, builder(routeContext)),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor:
          DialogTheme.of(context).barrierColor ??
          theme.dialogTheme.barrierColor ??
          Colors.black54,
      barrierDismissible: barrierDismissible,
      barrierLabel: barrierLabel,
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      animationStyle: MotionTokens.enabled(context)
          ? AnimationStyle(
              duration: MotionTokens.resolve(context, MotionTokens.dialog),
            )
          : AnimationStyle.noAnimation,
    ),
  );
}

/// Adaptive Forui calendar date picker rendered in an adaptive dialog/sheet
/// through [showAppAdaptiveDialog] so desktop, tablet and phone share one look.
Future<DateTime?> showAppDatePicker({
  required BuildContext context,
  required DateTime firstDate,
  required DateTime lastDate,
  required DateTime initialDate,
}) {
  return showAppAdaptiveDialog<DateTime>(
    context: context,
    maxWidth: 400,
    builder: (_) => AppDatePickerDialog(
      firstDate: firstDate,
      lastDate: lastDate,
      initialDate: initialDate,
    ),
  );
}

/// Adaptive popover: anchors a bounded floating panel beside [position] or
/// [anchorContext] (with screen-edge clamping) when [usePointerOverlay] holds,
/// falling back to a bounded [showAppAdaptiveDialog] on wide touch viewports
/// and to [showAppBottomSheet] on compact screens.
Future<T?> showAppAdaptivePopover<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  BuildContext? anchorContext,
  Offset? position,
  double minWidth = 260,
  double maxWidth = 340,
  double maxHeight = 440,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool showDragHandle = false,
  bool barrierDismissible = true,
  String? barrierLabel,
  bool? useRootNavigator,
}) {
  final resolvedUseRootNavigator = _resolveUseRootNavigator(
    context,
    useRootNavigator,
  );
  if (!usePointerOverlay(context)) {
    if (useWideOverlay(context)) {
      return showAppAdaptiveDialog<T>(
        context: context,
        builder: builder,
        maxWidth: math.max(maxWidth, 380),
        backgroundColor: backgroundColor,
        isScrollControlled: isScrollControlled,
        useSafeArea: useSafeArea,
        showDragHandle: showDragHandle,
        barrierDismissible: barrierDismissible,
        barrierLabel: barrierLabel,
        useRootNavigator: resolvedUseRootNavigator,
      );
    }
    return showAppBottomSheet<T>(
      context: context,
      builder: builder,
      backgroundColor: backgroundColor,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: showDragHandle,
      useRootNavigator: resolvedUseRootNavigator,
    );
  }
  final navigator = Navigator.of(
    context,
    rootNavigator: resolvedUseRootNavigator,
  );
  final theme = Theme.of(context);
  final localizations = MaterialLocalizations.of(context);
  final surfaceColor =
      backgroundColor ??
      theme.bottomSheetTheme.backgroundColor ??
      theme.colorScheme.surfaceContainerHigh;
  final anchorRect = _resolveAnchorRect(
    navigator: navigator,
    anchorContext: anchorContext ?? context,
    position: position,
  );
  return navigator.push(
    _AppAdaptivePopoverRoute<T>(
      builder: (routeContext) => Material(
        color: surfaceColor,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: _overlayBorder(routeContext),
        ),
        clipBehavior: Clip.antiAlias,
        child: MediaQuery.removePadding(
          context: routeContext,
          removeTop: true,
          removeBottom: true,
          removeLeft: true,
          removeRight: true,
          child: _clampingScroll(routeContext, builder(routeContext)),
        ),
      ),
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      anchorRect: anchorRect,
      preferPointOrigin: position != null,
      minWidth: minWidth,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      barrierDismissible: barrierDismissible,
      barrierLabel: barrierLabel ?? localizations.scrimLabel,
      duration: MotionTokens.resolve(context, MotionTokens.stateFade),
      reverseDuration: MotionTokens.resolve(context, MotionTokens.stateFade),
    ),
  );
}

/// Adaptive side sheet: slides in from the trailing edge when [useWideOverlay]
/// holds, falling back to [showAppBottomSheet] on compact viewports.
Future<T?> showAppAdaptiveSideSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double width = 400,
  Color? backgroundColor,
  bool isScrollControlled = true,
  bool useSafeArea = true,
  bool showDragHandle = false,
  bool barrierDismissible = true,
  String? barrierLabel,
  bool? useRootNavigator,
}) {
  final resolvedUseRootNavigator = _resolveUseRootNavigator(
    context,
    useRootNavigator,
  );
  if (!useWideOverlay(context)) {
    return showAppBottomSheet<T>(
      context: context,
      builder: builder,
      backgroundColor: backgroundColor,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: showDragHandle,
      useRootNavigator: resolvedUseRootNavigator,
    );
  }
  final navigator = Navigator.of(
    context,
    rootNavigator: resolvedUseRootNavigator,
  );
  final topClearance = _desktopCommandBarTopClearance(context, navigator);
  final theme = Theme.of(context);
  final localizations = MaterialLocalizations.of(context);
  final surfaceColor =
      backgroundColor ??
      theme.bottomSheetTheme.backgroundColor ??
      theme.colorScheme.surfaceContainerLow;
  final (enterDuration, curve) = MotionTokens.springCurve(
    context,
    MotionSpring.spatialDefault,
  );
  return navigator.push(
    _AppAdaptiveSideSheetRoute<T>(
      topClearance: topClearance,
      builder: (routeContext) {
        final rtl = Directionality.of(routeContext) == TextDirection.rtl;
        final sheetWidth = math.min(
          width,
          math.min(MediaQuery.sizeOf(routeContext).width * 0.72, 640.0),
        );
        return _withTopClearance(
          topClearance,
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: SizedBox(
              width: sheetWidth,
              height: double.infinity,
              child: Material(
                color: surfaceColor,
                surfaceTintColor: Colors.transparent,
                elevation: 6,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadiusDirectional.horizontal(
                    start: FuncShape.sheet.topLeft,
                  ),
                  side: _overlayBorder(routeContext),
                ),
                clipBehavior: Clip.antiAlias,
                child: MediaQuery.removePadding(
                  context: routeContext,
                  removeLeft: !rtl,
                  removeRight: rtl,
                  child: _clampingScroll(routeContext, builder(routeContext)),
                ),
              ),
            ),
          ),
        );
      },
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor:
          theme.bottomSheetTheme.modalBarrierColor ??
          theme.dialogTheme.barrierColor ??
          Colors.black54,
      barrierDismissible: barrierDismissible,
      barrierLabel: barrierLabel ?? localizations.scrimLabel,
      duration: enterDuration,
      reverseDuration: MotionTokens.resolve(context, MotionTokens.sheetExit),
      curve: curve,
    ),
  );
}

/// Pointer-anchored menu entry: the context menu a secondary click opens
/// on a PC (PAGE-18). The M3 popup menu at [position], with the app's own
/// width cap applied by the caller.
///
/// This one keeps Material's own popup route: its barrier closes on an
/// outside tap and Esc, not on the release-to-dismiss gesture of
/// [showAppBottomSheet] and [showAppPanel] (FB-02). QUAL-05's scene comes
/// from the caller's rows (see `showDisplayActions`), since the popup
/// route's class is private to Material.
Future<T?> showAppContextMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  BoxConstraints? constraints,
}) => showMenu<T>(
  context: context,
  position: position,
  items: items,
  useRootNavigator: true,
  constraints:
      constraints ?? const BoxConstraints(minWidth: 200, maxWidth: 360),
);

/// Alert/confirm dialog counterpart of [showAppBottomSheet]: one entry so
/// every dialog shares [MotionTokens.dialog] and the same reduced-motion
/// gate (zero duration, no transition), and the same release-to-dismiss
/// barrier.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String? barrierLabel,
  bool useRootNavigator = true,
  Offset? anchorPoint,
}) {
  // Mirrors showDialog's own route construction (the experimental
  // multi-window path aside).
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final resolvedAnchorPoint =
      anchorPoint ?? _railClearDialogAnchorPoint(context);
  return navigator.push(
    _AppDialogRoute<T>(
      context: context,
      builder: builder,
      anchorPoint: resolvedAnchorPoint,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor:
          DialogTheme.of(context).barrierColor ??
          Theme.of(context).dialogTheme.barrierColor ??
          Colors.black54,
      barrierDismissible: barrierDismissible,
      barrierLabel: barrierLabel,
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      animationStyle: MotionTokens.enabled(context)
          ? AnimationStyle(
              duration: MotionTokens.resolve(context, MotionTokens.dialog),
            )
          : AnimationStyle.noAnimation,
    ),
  );
}

/// A modal surface that places itself — the docked search input (NAV-25).
/// It is a transparent popup over the root navigator, under the app's
/// release-to-dismiss scrim and the same reduced-motion gate as a dialog;
/// [builder] lays out the page, which positions its own panel.
Future<T?> showAppPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required String barrierLabel,
  Color? barrierColor,
  bool useRootNavigator = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push(
    _AppPanelRoute<T>(
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierLabel: barrierLabel,
      barrierColor: barrierColor ?? Colors.black54,
      duration: MotionTokens.enabled(context)
          ? MotionTokens.resolve(context, MotionTokens.dialog)
          : Duration.zero,
    ),
  );
}

class _AppPanelRoute<T> extends PopupRoute<T> {
  _AppPanelRoute({
    required this.builder,
    required this.themes,
    required String barrierLabel,
    required Color barrierColor,
    required this.duration,
  }) : _barrierLabel = barrierLabel,
       _barrierColor = barrierColor;

  final WidgetBuilder builder;
  final CapturedThemes themes;
  final String _barrierLabel;
  final Color _barrierColor;
  final Duration duration;

  @override
  Duration get transitionDuration => duration;

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => _barrierColor;

  @override
  String? get barrierLabel => _barrierLabel;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => themes.wrap(builder(context));

  @override
  Widget buildModalBarrier() => PromptCover(
    animation: animation!,
    child: _ReleaseDismissBarrier(route: this),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(
    opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
    child: child,
  );

  var _probed = false;

  @override
  void install() {
    super.install();
    animation?.addStatusListener(_probeFade);
  }

  /// QUAL-05: the panel's fade is a scene a recording should name, in and
  /// out alike. Paired enter/exit, so the scene never leaks into the next
  /// frame's timing.
  void _probeFade(AnimationStatus status) {
    final active =
        status == AnimationStatus.forward || status == AnimationStatus.reverse;
    if (!FrameProbe.available || active == _probed) return;
    _probed = active;
    final probe = FrameProbe.instance;
    if (active) {
      probe
        ..enter('panel')
        ..mark('panel ${status == AnimationStatus.forward ? 'in' : 'out'}');
    } else {
      probe.exit('panel');
    }
  }

  @override
  void dispose() {
    animation?.removeStatusListener(_probeFade);
    super.dispose();
  }
}

class _AppDialogRoute<T> extends DialogRoute<T> {
  _AppDialogRoute({
    required super.context,
    required super.builder,
    this.topClearance = 0,
    super.anchorPoint,
    super.themes,
    super.barrierColor,
    super.barrierDismissible,
    super.barrierLabel,
    super.traversalEdgeBehavior,
    super.animationStyle,
  });

  final double topClearance;

  @override
  Widget buildModalBarrier() => _withTopClearance(
    topClearance,
    PromptCover(
      animation: animation!,
      child: _ReleaseDismissBarrier(route: this),
    ),
  );
}

class _AppBottomSheetRoute<T> extends PopupRoute<T>
    with ModalSheetRouteMixin<T> {
  _AppBottomSheetRoute({
    required this.builder,
    required this.capturedThemes,
    required String? barrierLabel,
    this.barrierOnTapHint,
    this.backgroundColor,
    this.modalBarrierColor,
    required this.showDragHandle,
    required this.isScrollControlled,
    required this.useSafeArea,
    required this.enterDuration,
    required this.exitDuration,
    required this.enterCurve,
  }) : _barrierLabel = barrierLabel;

  final WidgetBuilder builder;
  final CapturedThemes capturedThemes;
  final String? _barrierLabel;
  final String? barrierOnTapHint;
  final Color? backgroundColor;
  final Color? modalBarrierColor;
  final bool showDragHandle;
  final bool isScrollControlled;
  final bool useSafeArea;
  final Duration enterDuration;
  final Duration exitDuration;
  final Curve enterCurve;

  @override
  Duration get transitionDuration => enterDuration;

  @override
  Duration get reverseTransitionDuration => exitDuration;

  @override
  Curve get transitionCurve =>
      enterDuration == Duration.zero ? Curves.linear : enterCurve;

  @override
  bool get barrierDismissible => true;

  @override
  Color get barrierColor => modalBarrierColor ?? Colors.black54;

  @override
  String? get barrierLabel => _barrierLabel;

  @override
  bool get swipeDismissible => true;

  @override
  SwipeDismissSensitivity get swipeDismissSensitivity =>
      const SwipeDismissSensitivity(
        minFlingVelocityRatio: 1.5,
        dismissalOffset: SheetOffset(0.5),
      );

  @override
  ModalSheetBarrierBuilder<T>? get barrierBuilder => null;

  @override
  Widget buildViewport(BuildContext context, Widget child) {
    final topInset = useSafeArea ? MediaQuery.viewPaddingOf(context).top : 0.0;
    return capturedThemes.wrap(
      SheetViewport(
        padding: EdgeInsets.only(top: topInset),
        child: child,
      ),
    );
  }

  @override
  Widget buildSheet(BuildContext context) => AppBottomSheet(
    builder: builder,
    backgroundColor: backgroundColor,
    isScrollControlled: isScrollControlled,
    showDragHandle: showDragHandle,
  );

  @override
  Widget buildModalBarrier() => PromptCover(
    animation: animation!,
    child: _ReleaseDismissBarrier(route: this, onTapHint: barrierOnTapHint),
  );
}

/// Modal scrim that closes its route the way a native Android dialog does:
/// a touch that started on the scrim closes the route when it is released
/// outside the route's content — a tap or a drag alike. `ModalBarrier`
/// only reacts to a tap, so a drag outside left the dialog open.
///
/// It replaces the stock barrier rather than wrapping it: the stock tap
/// recognizer pops on the same release, and two pops would also close the
/// page below. The route is only popped while it is the current one, so a
/// single touch never closes two layers.
class _ReleaseDismissBarrier extends StatelessWidget {
  const _ReleaseDismissBarrier({required this.route, this.onTapHint});

  final ModalRoute<Object?> route;
  final String? onTapHint;

  void _dismiss() {
    if (route.isCurrent && !(route.navigator?.userGestureInProgress ?? false)) {
      route.navigator?.maybePop();
    }
  }

  /// Whether the release landed on the scrim itself. Outside the route's
  /// content the overlay hit test falls through the content entry to the
  /// barrier entry; over the content (a drag that ended inside the dialog)
  /// the barrier is not hit at all.
  bool _releasedOnBarrier(BuildContext context, PointerUpEvent event) {
    final self = context.findRenderObject();
    if (self == null) return false;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      event.position,
      View.of(context).viewId,
    );
    return result.path.any((entry) => entry.target == self);
  }

  @override
  Widget build(BuildContext context) {
    final dismissible = route.barrierDismissible;
    final label = route.barrierLabel;
    final semanticsDismissible =
        dismissible &&
        route.semanticsDismissible &&
        switch (defaultTargetPlatform) {
          TargetPlatform.android ||
          TargetPlatform.iOS ||
          TargetPlatform.macOS => true,
          TargetPlatform.fuchsia ||
          TargetPlatform.linux ||
          TargetPlatform.windows => false,
        };
    final color = route.barrierColor;
    final animation = route.animation!;
    Widget scrim = const SizedBox.expand();
    if (color != null && color.a != 0 && !route.offstage) {
      final transparent = color.withValues(alpha: 0);
      scrim = AnimatedBuilder(
        animation: animation,
        builder: (context, child) => ColoredBox(
          color: Color.lerp(
            transparent,
            color,
            route.barrierCurve.transform(animation.value),
          )!,
          child: child,
        ),
        child: scrim,
      );
    }
    return BlockSemantics(
      child: ExcludeSemantics(
        excluding: !semanticsDismissible,
        child: Semantics(
          label: semanticsDismissible ? label : null,
          onTap: semanticsDismissible && label != null ? _dismiss : null,
          onDismiss: semanticsDismissible && label != null ? _dismiss : null,
          onTapHint: onTapHint,
          textDirection: semanticsDismissible && label != null
              ? Directionality.of(context)
              : null,
          child: MouseRegion(
            cursor: SystemMouseCursors.basic,
            // Opaque either way: the page below never sees these touches.
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerUp: dismissible
                  ? (event) {
                      if (_releasedOnBarrier(context, event)) _dismiss();
                    }
                  : null,
              child: scrim,
            ),
          ),
        ),
      ),
    );
  }
}

Rect? _resolveAnchorRect({
  required NavigatorState navigator,
  required BuildContext anchorContext,
  Offset? position,
}) {
  final overlayRo = navigator.overlay?.context.findRenderObject();
  if (overlayRo is! RenderBox || !overlayRo.hasSize) return null;
  if (position != null) {
    final local = overlayRo.globalToLocal(position);
    return Rect.fromLTWH(local.dx, local.dy, 0, 0);
  }
  if (!anchorContext.mounted) return null;
  final ro = anchorContext.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize || !ro.attached) return null;
  return MatrixUtils.transformRect(
    ro.getTransformTo(overlayRo),
    Offset.zero & ro.size,
  );
}

class _AppAdaptivePopoverRoute<T> extends PopupRoute<T> {
  _AppAdaptivePopoverRoute({
    required this.builder,
    required this.themes,
    required this.anchorRect,
    required this.preferPointOrigin,
    required this.minWidth,
    required this.maxWidth,
    required this.maxHeight,
    required bool barrierDismissible,
    required String barrierLabel,
    required this.duration,
    required this.reverseDuration,
  }) : _barrierDismissible = barrierDismissible,
       _barrierLabel = barrierLabel;

  final WidgetBuilder builder;
  final CapturedThemes themes;
  final Rect? anchorRect;
  final bool preferPointOrigin;
  final double minWidth;
  final double maxWidth;
  final double maxHeight;
  final bool _barrierDismissible;
  final String _barrierLabel;
  final Duration duration;
  final Duration reverseDuration;

  @override
  Duration get transitionDuration => duration;

  @override
  Duration get reverseTransitionDuration => reverseDuration;

  @override
  bool get barrierDismissible => _barrierDismissible;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  String? get barrierLabel => _barrierLabel;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => themes.wrap(
    CustomSingleChildLayout(
      delegate: _PopoverLayoutDelegate(
        anchor: anchorRect,
        padding:
            MediaQuery.paddingOf(context) +
            const EdgeInsets.all(FuncSpacing.md),
        textDirection: Directionality.of(context),
        preferPointOrigin: preferPointOrigin,
        minWidth: minWidth,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ),
      child: builder(context),
    ),
  );

  @override
  Widget buildModalBarrier() => PromptCover(
    animation: animation!,
    child: _ReleaseDismissBarrier(route: this),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (duration == Duration.zero) return child;
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: MotionTokens.stateFadeCurve)),
      child: ScaleTransition(
        scale: animation.drive(
          Tween<double>(
            begin: 0.94,
            end: 1.0,
          ).chain(CurveTween(curve: Curves.easeOutCubic)),
        ),
        child: child,
      ),
    );
  }
}

class _PopoverLayoutDelegate extends SingleChildLayoutDelegate {
  _PopoverLayoutDelegate({
    required this.anchor,
    required this.padding,
    required this.textDirection,
    required this.preferPointOrigin,
    required this.minWidth,
    required this.maxWidth,
    required this.maxHeight,
  });

  final Rect? anchor;
  final EdgeInsets padding;
  final TextDirection textDirection;
  final bool preferPointOrigin;
  final double minWidth;
  final double maxWidth;
  final double maxHeight;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final availableWidth = math.max(
      0.0,
      constraints.maxWidth - padding.horizontal,
    );
    final availableHeight = math.max(
      0.0,
      constraints.maxHeight - padding.vertical,
    );
    final effectiveMaxWidth = math.min(maxWidth, availableWidth);
    return BoxConstraints(
      minWidth: math.min(minWidth, effectiveMaxWidth),
      maxWidth: effectiveMaxWidth,
      maxHeight: math.min(maxHeight, availableHeight),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bounds = Rect.fromLTWH(
      padding.left,
      padding.top,
      math.max(0.0, size.width - padding.horizontal),
      math.max(0.0, size.height - padding.vertical),
    );
    final target = anchor;
    if (target == null) {
      return Offset(
        bounds.left + math.max(0.0, (bounds.width - childSize.width) / 2),
        bounds.top + math.max(0.0, (bounds.height - childSize.height) / 2),
      );
    }
    final maxDx = math.max(bounds.left, bounds.right - childSize.width);
    final maxDy = math.max(bounds.top, bounds.bottom - childSize.height);

    final double rawX;
    if (preferPointOrigin) {
      rawX =
          target.left + childSize.width > bounds.right &&
              target.left - childSize.width >= bounds.left
          ? target.left - childSize.width
          : target.left;
    } else if (textDirection == TextDirection.rtl) {
      rawX = target.right - childSize.width;
    } else {
      rawX = target.left;
    }
    final dx = rawX.clamp(bounds.left, maxDx);

    final double rawY;
    if (preferPointOrigin) {
      rawY =
          target.top + childSize.height > bounds.bottom &&
              target.top - childSize.height >= bounds.top
          ? target.top - childSize.height
          : target.top;
    } else {
      const gap = 6.0;
      final belowY = target.bottom + gap;
      final aboveY = target.top - gap - childSize.height;
      if (belowY + childSize.height <= bounds.bottom) {
        rawY = belowY;
      } else if (aboveY >= bounds.top) {
        rawY = aboveY;
      } else {
        final spaceBelow = bounds.bottom - target.bottom;
        final spaceAbove = target.top - bounds.top;
        rawY = spaceAbove > spaceBelow ? aboveY : belowY;
      }
    }
    final dy = rawY.clamp(bounds.top, maxDy);
    return Offset(dx, dy);
  }

  @override
  bool shouldRelayout(_PopoverLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor ||
      padding != oldDelegate.padding ||
      textDirection != oldDelegate.textDirection ||
      preferPointOrigin != oldDelegate.preferPointOrigin ||
      minWidth != oldDelegate.minWidth ||
      maxWidth != oldDelegate.maxWidth ||
      maxHeight != oldDelegate.maxHeight;
}

class _AppAdaptiveSideSheetRoute<T> extends PopupRoute<T> {
  _AppAdaptiveSideSheetRoute({
    required this.builder,
    required this.themes,
    required Color barrierColor,
    required bool barrierDismissible,
    required String barrierLabel,
    required this.duration,
    required this.reverseDuration,
    required this.curve,
    this.topClearance = 0,
  }) : _barrierColor = barrierColor,
       _barrierDismissible = barrierDismissible,
       _barrierLabel = barrierLabel;

  final WidgetBuilder builder;
  final CapturedThemes themes;
  final Color _barrierColor;
  final bool _barrierDismissible;
  final String _barrierLabel;
  final Duration duration;
  final Duration reverseDuration;
  final Curve curve;
  final double topClearance;

  @override
  Duration get transitionDuration => duration;

  @override
  Duration get reverseTransitionDuration => reverseDuration;

  @override
  bool get barrierDismissible => _barrierDismissible;

  @override
  Color? get barrierColor => _barrierColor;

  @override
  String? get barrierLabel => _barrierLabel;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => themes.wrap(builder(context));

  @override
  Widget buildModalBarrier() => _withTopClearance(
    topClearance,
    PromptCover(
      animation: animation!,
      child: _ReleaseDismissBarrier(route: this),
    ),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (duration == Duration.zero) return child;
    final begin = Directionality.of(context) == TextDirection.rtl
        ? const Offset(-1, 0)
        : const Offset(1, 0);
    return SlideTransition(
      position: animation.drive(
        Tween<Offset>(
          begin: begin,
          end: Offset.zero,
        ).chain(CurveTween(curve: curve)),
      ),
      child: child,
    );
  }
}
