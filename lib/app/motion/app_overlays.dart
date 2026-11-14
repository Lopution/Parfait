import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show HitTestResult, PointerUpEvent;
import 'package:material_ui/material_ui.dart';

import '../../core/debug/frame_probe.dart';
import '../layout/app_breakpoints.dart';
import '../layout/input_modality.dart';
import '../theme/func_semantic_tokens.dart';
import '../widgets/prompt_host.dart';
import 'motion_tokens.dart';

/// Whether secondary overlays should use bounded container presentations
/// (centered dialog or side sheet) rather than full-width bottom sheets.
///
/// Determined purely by viewport width so touch tablets gain bounded dialogs
/// and side sheets just like desktop windows.
bool useWideOverlay(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= AppBreakpoints.medium;

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

/// App-wide modal bottom sheet entry: one presentation spring and one
/// reduced-motion gate for every sheet. Under reduced motion the sheet
/// snaps open via [AnimationStyle.noAnimation] — the state change still
/// lands, only the slide is removed.
///
/// The scrim closes the sheet when a touch outside it is released there —
/// a drag counts, not just a tap (see [_ReleaseDismissBarrier]).
///
/// Content scrolls clamped, and only when it overflows. The app-wide
/// bouncing, always-scrollable physics took every vertical drag: the
/// content rubber-banded inside a panel that never moved, and the sheet
/// could not be dragged closed. With nothing to scroll, the drag reaches
/// the sheet. A vertical `ListView` forces always-scrollable physics on
/// its own — sheet content passes `primary: false` to it.
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool showDragHandle = false,
  bool useRootNavigator = false,
}) {
  // Mirrors showModalBottomSheet's own route construction.
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final localizations = MaterialLocalizations.of(context);
  return navigator.push(
    _AppBottomSheetRoute<T>(
      builder: (context) => _clampingScroll(context, builder(context)),
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
      sheetAnimationStyle: _sheetAnimationStyle(context),
    ),
  );
}

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
  bool useRootNavigator = false,
}) {
  if (!useWideOverlay(context)) {
    return showAppBottomSheet<T>(
      context: context,
      builder: builder,
      backgroundColor: backgroundColor,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: showDragHandle,
      useRootNavigator: useRootNavigator,
    );
  }
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final theme = Theme.of(context);
  final surfaceColor =
      backgroundColor ??
      theme.bottomSheetTheme.backgroundColor ??
      theme.colorScheme.surfaceContainerHigh;
  return navigator.push(
    _AppDialogRoute<T>(
      context: context,
      builder: (routeContext) {
        final window = MediaQuery.sizeOf(routeContext);
        final keyboardInset = MediaQuery.viewInsetsOf(routeContext).bottom;
        final boundedMaxWidth = math.min(
          maxWidth,
          math.min(window.width * 0.72, 640.0),
        );
        return Padding(
          padding: EdgeInsets.only(bottom: keyboardInset),
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
                  shape: const RoundedRectangleBorder(
                    borderRadius: FuncShape.dialog,
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
  bool useRootNavigator = false,
}) {
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
        useRootNavigator: useRootNavigator,
      );
    }
    return showAppBottomSheet<T>(
      context: context,
      builder: builder,
      backgroundColor: backgroundColor,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: showDragHandle,
      useRootNavigator: useRootNavigator,
    );
  }
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
  bool useRootNavigator = false,
}) {
  if (!useWideOverlay(context)) {
    return showAppBottomSheet<T>(
      context: context,
      builder: builder,
      backgroundColor: backgroundColor,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: showDragHandle,
      useRootNavigator: useRootNavigator,
    );
  }
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
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
      builder: (routeContext) {
        final rtl = Directionality.of(routeContext) == TextDirection.rtl;
        final sheetWidth = math.min(
          width,
          math.min(MediaQuery.sizeOf(routeContext).width * 0.72, 640.0),
        );
        return Align(
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

/// Opens on the [MotionSpring.spatialDefault] spring; closes over Material's
/// 200 ms exit, which the reversed spring curve accelerates away.
AnimationStyle _sheetAnimationStyle(BuildContext context) {
  final (duration, curve) = MotionTokens.springCurve(
    context,
    MotionSpring.spatialDefault,
  );
  if (duration == Duration.zero) return AnimationStyle.noAnimation;
  return AnimationStyle(
    duration: duration,
    curve: curve,
    reverseDuration: MotionTokens.resolve(context, MotionTokens.sheetExit),
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
  constraints: constraints,
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
}) {
  // Mirrors showDialog's own route construction (the experimental
  // multi-window path aside).
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push(
    _AppDialogRoute<T>(
      context: context,
      builder: builder,
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
    super.themes,
    super.barrierColor,
    super.barrierDismissible,
    super.barrierLabel,
    super.traversalEdgeBehavior,
    super.animationStyle,
  });

  @override
  Widget buildModalBarrier() => PromptCover(
    animation: animation!,
    child: _ReleaseDismissBarrier(route: this),
  );
}

class _AppBottomSheetRoute<T> extends ModalBottomSheetRoute<T> {
  _AppBottomSheetRoute({
    required super.builder,
    super.capturedThemes,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.backgroundColor,
    super.modalBarrierColor,
    super.showDragHandle,
    required super.isScrollControlled,
    super.useSafeArea,
    super.sheetAnimationStyle,
  });

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
    if (route.isCurrent) route.navigator?.maybePop();
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
