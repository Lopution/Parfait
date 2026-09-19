import 'package:material_ui/material_ui.dart';

import '../motion/motion_tokens.dart';

/// Shared SnackBar in/out motion (U4): the M2 default only animates a
/// floating SnackBar's opacity in the 0.4–1.0 interval, so the ~120ms
/// default paints ~72ms of fade — it reads as "no animation" on device.
/// medium/fast keeps the whole cycle perceptible without lingering.
const appSnackBarAnimationStyle = AnimationStyle(
  duration: MotionTokens.medium,
  reverseDuration: MotionTokens.fast,
);

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
/// SnackBars resolve the nearest messenger: pages whose Scaffold owns a
/// bottom bar host a messenger inside `body` (see `BranchRootScaffold`), so
/// a floating SnackBar lands inside the content area instead of covering
/// the bar.
void showAppSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
  SnackBarAction? action,
}) {
  showAppSnackBarOn(
    ScaffoldMessenger.maybeOf(context),
    message,
    duration: duration,
    action: action,
  );
}

/// Messenger-direct variant for call sites that hold a messenger key
/// instead of a context (e.g. the app-level update prompt).
void showAppSnackBarOn(
  ScaffoldMessengerState? messenger,
  String message, {
  Duration duration = const Duration(seconds: 4),
  SnackBarAction? action,
  EdgeInsets margin = const EdgeInsets.fromLTRB(16, 0, 16, 16),
}) {
  messenger?.showSnackBar(
    buildAppSnackBar(
      message,
      duration: duration,
      action: action,
      margin: margin,
    ),
    snackBarAnimationStyle: appSnackBarAnimationStyle,
  );
}
