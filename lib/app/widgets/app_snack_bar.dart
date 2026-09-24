import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../motion/motion_tokens.dart';
import '../navigation/home_shell_metrics.dart';
import 'func_bottom_nav.dart';

/// Shared SnackBar in/out motion (U4): the M2 default only animates a
/// floating SnackBar's opacity in the 0.4–1.0 interval, so the ~120ms
/// default paints ~72ms of fade — it reads as "no animation" on device.
/// medium/fast keeps the whole cycle perceptible without lingering.
const appSnackBarAnimationStyle = AnimationStyle(
  duration: MotionTokens.medium,
  reverseDuration: MotionTokens.fast,
);

/// The snackbar's in/out flight resolved through the reduced-motion gate —
/// the same [AnimationStyle.noAnimation] collapse the overlays use. The
/// message, dwell duration and action are the feedback and always land;
/// only the slide/fade flight is decoration.
AnimationStyle snackBarAnimationStyleFor(BuildContext context) =>
    MotionTokens.enabled(context)
    ? appSnackBarAnimationStyle
    : AnimationStyle.noAnimation;

/// Builds the one in-app SnackBar shape: floating, a consistent margin and
/// an optional action. Keeping construction in one place is what makes the
/// position identical on every page — call sites must not hand-roll
/// behavior/margin.
SnackBar buildAppSnackBar(
  String message, {
  Duration duration = const Duration(seconds: 4),
  SnackBarAction? action,
  EdgeInsets margin = const EdgeInsets.fromLTRB(16, 0, 16, 16),
}) {
  return SnackBar(
    content: Text(message),
    duration: duration,
    behavior: SnackBarBehavior.floating,
    margin: margin,
    action: action,
  );
}

/// Single owner of in-app SnackBar presentation (C5d).
///
/// Callers pass a localized message; duration escapes only when a call site
/// genuinely needs longer dwell time (default 4s matches Material guidance).
/// SnackBars resolve the nearest messenger: branch-root pages host one
/// inside `BranchRootScaffold`, so the SnackBar renders inside the branch
/// page's Scaffold and hides while a pushed route covers it.
///
/// The shell bottom bar floats over branch-root pages as an overlay, so
/// Scaffold geometry cannot anchor the SnackBar above it — on a branch
/// root (`BranchRootScope`) the margin is grown by the measured bar
/// height. Pushed routes resolve the root messenger outside the scope and
/// keep the plain margin, matching the bar having slid away.
void showAppSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
  SnackBarAction? action,
  bool replaceCurrent = true,
}) {
  var margin = const EdgeInsets.fromLTRB(16, 0, 16, 16);
  if (BranchRootScope.maybeOf(context) != null) {
    final metrics = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(homeShellMetricsProvider);
    final barHeight = metrics.bottomNavHeight;
    if (barHeight != null) {
      // The shell bar is a transformed overlay. During auto-hide its render
      // box still has the full height, so use its measured screen top when it
      // is available and only fall back to the full height before measurement.
      final visibleOverlap = metrics.bottomNavTop == null
          ? barHeight
          : (MediaQuery.sizeOf(context).height - metrics.bottomNavTop!).clamp(
              0.0,
              barHeight,
            );
      margin = margin.copyWith(bottom: margin.bottom + visibleOverlap);
    }
  }
  showAppSnackBarOn(
    ScaffoldMessenger.maybeOf(context),
    message,
    duration: duration,
    action: action,
    replaceCurrent: replaceCurrent,
    margin: margin,
    animationStyle: snackBarAnimationStyleFor(context),
  );
}

/// Messenger-direct variant for call sites that hold a messenger key
/// instead of a context (e.g. the app-level update prompt).
///
/// [animationStyle] defaults to [snackBarAnimationStyleFor] resolved on the
/// messenger's own context — a branch messenger sits below `MotionScope`,
/// so the gate is complete there. Callers whose messenger lives ABOVE the
/// scope (the root messenger used by the update prompt / exit hint) must
/// pass an explicitly resolved style or the in-app setting is missed.
void showAppSnackBarOn(
  ScaffoldMessengerState? messenger,
  String message, {
  Duration duration = const Duration(seconds: 4),
  SnackBarAction? action,
  bool replaceCurrent = true,
  EdgeInsets margin = const EdgeInsets.fromLTRB(16, 0, 16, 16),
  AnimationStyle? animationStyle,
}) {
  if (replaceCurrent) messenger?.clearSnackBars();
  messenger?.showSnackBar(
    buildAppSnackBar(
      message,
      duration: duration,
      action: action,
      margin: margin,
    ),
    snackBarAnimationStyle:
        animationStyle ?? snackBarAnimationStyleFor(messenger.context),
  );
}
