import 'package:material_ui/material_ui.dart';

import '../motion/motion_tokens.dart';
import '../navigation/home_shell_metrics.dart';
import '../theme/func_semantic_tokens.dart';
import 'func_bottom_nav.dart';

/// Shared SnackBar in/out motion (U4): the M2 default only animates a
/// floating SnackBar's opacity in the 0.4–1.0 interval, so the ~120ms
/// default paints ~72ms of fade — it reads as "no animation" on device.
/// medium/fast keeps the whole cycle perceptible without lingering.
///
/// [resolve] maps each base duration through the motion gate and speed; a
/// closed gate collapses to [AnimationStyle.noAnimation], the same collapse
/// the overlays use. The message, dwell duration and action are the
/// feedback and always land; only the slide/fade flight is decoration.
AnimationStyle appSnackBarAnimationStyle(
  Duration Function(Duration base) resolve,
) {
  final duration = resolve(MotionTokens.medium);
  if (duration == Duration.zero) return AnimationStyle.noAnimation;
  return AnimationStyle(
    duration: duration,
    reverseDuration: resolve(MotionTokens.fast),
  );
}

/// [appSnackBarAnimationStyle] resolved from [context]'s motion scope.
AnimationStyle snackBarAnimationStyleFor(BuildContext context) =>
    appSnackBarAnimationStyle((base) => MotionTokens.resolve(context, base));

/// The margin every in-app SnackBar starts from; presenters grow its
/// bottom edge when the floating shell bar occupies the same space.
const _baseMargin = EdgeInsets.fromLTRB(
  FuncSpacing.lg,
  0,
  FuncSpacing.lg,
  FuncSpacing.lg,
);

/// The margin for a floating SnackBar that must clear the home shell's
/// bottom bar: base margin plus the bar's **resting** extent. The bar
/// slides under the screen edge as an overlay while the snackbar dwells;
/// lifting by the resting extent keeps the message clear of the bar both
/// when it is shown and when it slides back mid-dwell.
EdgeInsets appSnackBarShellMargin(double bottomBarExtent) =>
    _baseMargin.copyWith(bottom: _baseMargin.bottom + bottomBarExtent);

/// Builds the one in-app SnackBar shape: floating, a consistent margin and
/// an optional action. Keeping construction in one place is what makes the
/// position identical on every page — call sites must not hand-roll
/// behavior/margin.
SnackBar buildAppSnackBar(
  String message, {
  Duration duration = const Duration(seconds: 4),
  SnackBarAction? action,
  EdgeInsets margin = _baseMargin,
  bool persist = false,
}) {
  return SnackBar(
    content: Text(message),
    duration: duration,
    behavior: SnackBarBehavior.floating,
    margin: margin,
    action: action,
    persist: persist,
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
/// root (`BranchRootScope`) the margin is grown by the shell's computed
/// bar extent. Pushed routes resolve the root messenger outside the scope
/// and keep the plain margin, matching the bar having slid away.
void showAppSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
  SnackBarAction? action,
  bool replaceCurrent = true,
}) {
  var margin = _baseMargin;
  if (BranchRootScope.maybeOf(context) != null) {
    margin = appSnackBarShellMargin(
      HomeShellChrome.maybeOf(context)?.bottomBarExtent ?? 0,
    );
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
  EdgeInsets margin = _baseMargin,
  AnimationStyle? animationStyle,
}) {
  if (messenger == null) return;
  if (replaceCurrent) messenger.clearSnackBars();
  messenger.showSnackBar(
    buildAppSnackBar(
      message,
      duration: duration,
      action: action,
      margin: margin,
      // material_ui defaults `persist` to `action != null`, so a snackbar
      // with a button used to stay forever. Only accessible navigation
      // still pins it — screen-reader users need the action reachable.
      persist:
          action != null &&
          MediaQuery.accessibleNavigationOf(messenger.context),
    ),
    snackBarAnimationStyle:
        animationStyle ?? snackBarAnimationStyleFor(messenger.context),
  );
}
