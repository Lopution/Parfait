import 'package:flutter/widgets.dart';

import 'prompt_host.dart';

export 'prompt_host.dart' show PromptAction, defaultPromptDuration;

/// Single entry for in-app transient feedback (C5d).
///
/// Callers pass a localized message; duration escapes only when a call site
/// genuinely needs longer dwell time. The prompt goes to the app's one
/// [PromptHost], which places it above the bottom chrome on screen and
/// keeps it across navigation — position, motion and dwell are never the
/// caller's business.
///
/// Returns a callback that takes the prompt down early, for a message that
/// stops being true before its dwell ends.
VoidCallback showAppSnackBar(
  BuildContext context,
  String message, {
  Duration duration = defaultPromptDuration,
  PromptAction? action,
  bool replaceCurrent = true,
}) {
  return PromptHost.of(context).show(
    message,
    duration: duration,
    action: action,
    replaceCurrent: replaceCurrent,
  );
}

/// [showAppSnackBar] for feedback that lands after an await: the host is
/// taken now, so the returned callback still shows [message] once the
/// context that asked is gone.
VoidCallback deferAppSnackBar(BuildContext context, String message) {
  final host = PromptHost.of(context);
  return () {
    if (host.mounted) host.show(message);
  };
}
