import '../../core/auth/oauth_service.dart';
import '../../core/auth/pkce.dart';

/// Pure navigation decision for the OAuth login WebView: an exact
/// `pixiv://account?code=…` redirect is the only completed login; anything
/// else belongs to Pixiv's own login flow.
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

/// Extracts an OAuth authorization code from pasted callback input.
///
/// Accepts:
/// 1. `pixiv://account...` callback URIs,
/// 2. `https://...` callback URIs containing a single non-empty `code` parameter,
/// 3. a bare authorization code token (`[A-Za-z0-9_.-]{16,512}`).
String? parsePixivCallbackCode(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (!trimmed.contains(':') &&
      !trimmed.contains('/') &&
      !trimmed.contains('?') &&
      RegExp(r'^[A-Za-z0-9_.-]{16,512}$').hasMatch(trimmed)) {
    return trimmed;
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (uri.scheme == 'pixiv') {
    final parsed = parsePixivAccountCallback(uri);
    return parsed is PixivCallbackCode ? parsed.code : null;
  }
  if (uri.scheme == 'https' || uri.scheme == 'http') {
    final codes = uri.queryParametersAll['code'];
    if (codes == null || codes.length != 1) return null;
    final code = codes.single.trim();
    return code.isEmpty ? null : code;
  }
  return null;
}

/// Normalizes a valid manual callback input into the canonical `pixiv://account`
/// URI consumed by [decideLoginNavigation], preserving optional `state` when
/// supplied in a callback URL.
Uri? normalizeManualPixivCallbackUri(String raw) {
  final code = parsePixivCallbackCode(raw);
  if (code == null) return null;
  final uri = Uri.tryParse(raw.trim());
  final states = uri?.queryParametersAll['state'];
  final state = states != null && states.length == 1 ? states.single : null;
  return Uri(
    scheme: 'pixiv',
    host: 'account',
    path: '/login',
    queryParameters: {'code': code, 'state': ?state},
  );
}
