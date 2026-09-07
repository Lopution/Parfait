import '../platform/intent_router.dart';

/// Decision surface for the controlled SauceNAO result WebView (D1).
///
/// Navigates freely inside saucenao.com, routes Pixiv links into the app
/// (illust detail / user page), sends every other HTTPS link to the external
/// launcher and rejects non-HTTPS navigation outright. Kept free of widget
/// code so the security-relevant policy is unit-testable.
enum SauceNaoNavigationAction {
  /// Stay inside the controlled WebView (saucenao.com only).
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

abstract final class SauceNaoNavigationPolicy {
  static const Set<String> webViewSites = {
    'saucenao.com',
    'www.saucenao.com',
  };

  static SauceNaoNavigationAction decide(Uri? uri) {
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return SauceNaoNavigationAction.reject;
    }
    final host = uri.host.toLowerCase();
    if (webViewSites.contains(host)) {
      return SauceNaoNavigationAction.navigate;
    }
    if (uri.userInfo.isNotEmpty || uri.hasFragment) {
      return SauceNaoNavigationAction.reject;
    }
    switch (IntentRouter.route(uri)) {
      case IllustRoute():
        return SauceNaoNavigationAction.openIllust;
      case UserRoute():
        return SauceNaoNavigationAction.openUser;
      case ForeignUri() || UnknownRoute():
        return SauceNaoNavigationAction.openExternal;
      case AccountCallbackRoute():
        return SauceNaoNavigationAction.reject;
    }
  }
}
