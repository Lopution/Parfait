import 'package:material_ui/material_ui.dart';

/// Single owner of in-app SnackBar presentation (C5d).
///
/// Callers pass a localized message; duration escapes only when a call site
/// genuinely needs longer dwell time (default 4s matches Material guidance).
void showAppSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message), duration: duration));
}
