import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show HitTestResult, PointerUpEvent;
import 'package:material_ui/material_ui.dart';

import '../widgets/prompt_host.dart';
import 'motion_tokens.dart';

/// App-wide modal bottom sheet entry: one presentation spring and one
/// reduced-motion gate for every sheet. Under reduced motion the sheet
/// snaps open via [AnimationStyle.noAnimation] — the state change still
/// lands, only the slide is removed.
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
}) {
  // Mirrors showModalBottomSheet's own route construction.
  final navigator = Navigator.of(context);
  final localizations = MaterialLocalizations.of(context);
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
      sheetAnimationStyle: _sheetAnimationStyle(context),
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
    reverseDuration: MotionTokens.resolve(context, MotionTokens.medium),
  );
}

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
