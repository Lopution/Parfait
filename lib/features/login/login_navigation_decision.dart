import '../../core/auth/oauth_service.dart';
import '../../core/auth/pkce.dart';

/// Pure navigation decision for the OAuth login WebView, shared by the
/// `webview_flutter` page (Android/iOS) and the `flutter_inappwebview` page
/// (Windows desktop). Both surfaces must apply the exact same rule:
/// an exact `pixiv://account?code=…` redirect is the only completed login;
/// anything else belongs to Pixiv's own login flow.
sealed class LoginNavigationDecision {
  const LoginNavigationDecision();
}

/// The navigation may proceed; [uri] is the new main-frame location.
final class LoginNavAllow extends LoginNavigationDecision {
  const LoginNavAllow(this.uri);

  final Uri uri;
}

/// The redirect carried an authorization code — stop the navigation and run
/// the PKCE exchange.
final class LoginNavExchange extends LoginNavigationDecision {
  const LoginNavExchange(this.code);

  final String code;
}

/// The callback was reached with unusable parameters; the PKCE session is
/// dead and the page must abort instead of retrying in place.
final class LoginNavAbort extends LoginNavigationDecision {
  const LoginNavAbort(this.reason);

  final String reason;
}

/// The raw URL could not be parsed — let the platform webview decide.
final class LoginNavIgnore extends LoginNavigationDecision {
  const LoginNavIgnore();
}

LoginNavigationDecision decideLoginNavigation(
  OAuthService oauth,
  String rawUrl,
) {
  final Uri uri;
  try {
    uri = Uri.parse(rawUrl);
  } on FormatException {
    return const LoginNavIgnore();
  }
  return switch (oauth.validateRedirect(uri)) {
    PixivCallbackCode(:final code) => LoginNavExchange(code),
    PixivCallbackInvalid(:final reason) => LoginNavAbort(reason),
    PixivCallbackOther() => LoginNavAllow(uri),
  };
}
