import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';

/// Shared bottom-left error card for the authorization WebViews
/// (`login_webview_page.dart` on mobile, `login_webview_desktop_page.dart`
/// on Windows). Both pages render the identical surface — this widget owns
/// the structure so the two can no longer drift:
///
/// `Align(bottomLeft)` → `SafeArea` → `Padding(16)` →
/// `Card(errorContainer)` with the message and a consistent action row.
///
/// The action set encodes the shared contract:
///
/// - recoverable error → `onReload` ("重新加载") + `onDismiss` ("知道了");
/// - fatal error in login mode → `onRestart` ("重新登录") — the PKCE
///   session is dead and must be rebuilt in place;
/// - fatal error in signup mode → `onReload` only — there is no session
///   to restart, so reloading the document is the only recovery.
///
/// What each callback does is the caller's contract; this card only
/// decides which actions exist for a given error state.
class LoginWebViewErrorCard extends StatelessWidget {
  const LoginWebViewErrorCard({
    super.key,
    required this.message,
    required this.fatal,
    required this.signup,
    required this.onReload,
    required this.onRestart,
    required this.onDismiss,
  });

  /// Localized error description already resolved by the caller.
  final String message;

  /// Whether the error killed the PKCE session. Recoverable errors keep the
  /// session alive, so the same page can continue after a reload.
  final bool fatal;

  /// Signup (`create=true`) mode has no PKCE session — its fatal card can
  /// only reload the document, never restart a session.
  final bool signup;

  /// Reloads the current document in place (recoverable retry, and the
  /// fatal action in signup mode).
  final VoidCallback onReload;

  /// Rebuilds the OAuth session in place (fatal action in login mode).
  final VoidCallback onRestart;

  /// Clears a recoverable error without reloading.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomLeft,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(child: Text(message)),
                  if (fatal)
                    signup
                        ? TextButton(
                            onPressed: onReload,
                            child: Text(context.l10n.loginReload),
                          )
                        : TextButton(
                            onPressed: onRestart,
                            child: Text(context.l10n.loginRestart),
                          )
                  else ...[
                    TextButton(
                      onPressed: onReload,
                      child: Text(context.l10n.loginReload),
                    ),
                    TextButton(
                      onPressed: onDismiss,
                      child: Text(context.l10n.dismiss),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
