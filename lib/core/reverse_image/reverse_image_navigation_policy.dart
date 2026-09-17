import '../platform/intent_router.dart';
import 'reverse_image_engine.dart';

/// Decision surface for a controlled reverse-image WebView (D1).
///
/// Navigates freely inside the engine's own hosts, routes Pixiv links into
/// the app (illust detail / user page), sends every other HTTPS link to the
/// external launcher and rejects non-HTTPS navigation outright. Kept free of
/// widget code so the security-relevant policy is unit-testable.
enum ReverseImageNavigationAction {
  /// Stay inside the controlled WebView (engine hosts only).
  navigate,

  /// Open the illust detail page in the app; block the WebView navigation.
  openIllust,

  /// Open the user page in the app; block the WebView navigation.
  openUser,

  /// Hand the link to the external launcher; block the WebView navigation.
  openExternal,

  /// Reject (non-HTTPS, malformed). No fallback rendering is attempted.
  reject,
}

/// Per-engine navigation policy: [webViewHosts] is the engine's own host
/// set from [ReverseImageEngineSpec.webViewHosts]; every other rule is
/// engine-agnostic.
class ReverseImageNavigationPolicy {
  const ReverseImageNavigationPolicy(this.webViewHosts);

  /// Hosts the controlled WebView may navigate to. Lowercase, no scheme.
  final Set<String> webViewHosts;

  ReverseImageNavigationAction decide(Uri? uri) {
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return ReverseImageNavigationAction.reject;
    }
    final host = uri.host.toLowerCase();
    if (webViewHosts.contains(host)) {
      return ReverseImageNavigationAction.navigate;
    }
    if (uri.userInfo.isNotEmpty || uri.hasFragment) {
      return ReverseImageNavigationAction.reject;
    }
    switch (IntentRouter.route(uri)) {
      case IllustRoute():
        return ReverseImageNavigationAction.openIllust;
      case UserRoute():
        return ReverseImageNavigationAction.openUser;
      case ForeignUri() || UnknownRoute():
        return ReverseImageNavigationAction.openExternal;
      case AccountCallbackRoute():
        return ReverseImageNavigationAction.reject;
    }
  }
}
