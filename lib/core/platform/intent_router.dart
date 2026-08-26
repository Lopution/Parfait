/// Typed commands produced by parsing Android deep links.
sealed class DeepLinkRoute {
  const DeepLinkRoute();
}

/// Open a user page: `pixiv://users/<id>`, `pixivfunc://users/<id>`,
/// `https://www.pixiv.net/u/<id>`, `/users/<id>`, or `?id=<id>` on a user page.
class UserRoute extends DeepLinkRoute {
  const UserRoute(this.userId);

  final int userId;
}

/// Open an illust page: `pixiv://illusts/<id>`, `pixivfunc://illusts/<id>`,
/// `https://www.pixiv.net/i/<id>`, `/artworks/<id>`, or `?illust_id=<id>`.
class IllustRoute extends DeepLinkRoute {
  const IllustRoute(this.illustId);

  final int illustId;
}

/// OAuth account callback: pixiv://account?code=... Routed to the login flow.
class AccountCallbackRoute extends DeepLinkRoute {
  const AccountCallbackRoute(this.code);

  final String code;
}

/// A URI that parsed but does not map to a known destination. The app shows
/// the original beta56 behaviour: an "invalid id" toast, never a crash.
class UnknownRoute extends DeepLinkRoute {
  const UnknownRoute(this.reason);

  final String reason;
}

/// A URI from a foreign scheme/host. The app must ignore it entirely.
class ForeignUri extends DeepLinkRoute {
  const ForeignUri(this.uri);

  final Uri uri;
}

/// Validates and maps incoming Android URIs to typed routes.
///
/// Behaviour mirrors beta56 `UrlScheme` (visible contract) while rejecting
/// malformed input at the boundary instead of navigating blindly.
abstract final class IntentRouter {
  static const Set<String> _webHosts = {'pixiv.net', 'www.pixiv.net'};
  static const Set<String> _pixivHosts = {'users', 'illusts', 'account'};
  static const Set<String> _pixivfuncHosts = {'users', 'illusts'};

  static DeepLinkRoute route(Uri uri) {
    switch (uri.scheme) {
      case 'pixiv':
        if (!_pixivHosts.contains(uri.host)) return const UnknownRoute('unknown pixiv host');
        if (uri.host == 'account') {
          final codes = uri.queryParametersAll['code'];
          if (codes == null || codes.length != 1 || codes.single.isEmpty) {
            return const UnknownRoute('account callback without code');
          }
          return AccountCallbackRoute(codes.single);
        }
        return _typedIdFromLastSegment(uri, uri.host);
      case 'pixivfunc':
        if (!_pixivfuncHosts.contains(uri.host)) {
          return const UnknownRoute('unknown pixivfunc host');
        }
        return _typedIdFromLastSegment(uri, uri.host);
      case 'http':
      case 'https':
        if (!_webHosts.contains(uri.host)) return ForeignUri(uri);
        return _routeWebPath(uri);
      default:
        return ForeignUri(uri);
    }
  }

  static DeepLinkRoute _typedIdFromLastSegment(Uri uri, String host) {
    if (uri.pathSegments.isEmpty) {
      return UnknownRoute('missing id in $host link');
    }
    final id = int.tryParse(uri.pathSegments.last);
    if (id == null || id <= 0) {
      return UnknownRoute('invalid id: ${uri.pathSegments.last}');
    }
    return host == 'users' ? UserRoute(id) : IllustRoute(id);
  }

  static DeepLinkRoute _routeWebPath(Uri uri) {
    final segments = uri.pathSegments;
    int? idFrom(String segment) {
      final index = segments.indexOf(segment);
      if (index < 0 || index + 1 >= segments.length) return null;
      final id = int.tryParse(segments[index + 1]);
      return (id == null || id <= 0) ? null : id;
    }

    // u/<id> user, i/<id> or artworks/<id> illust (beta56 paths).
    final userId = idFrom('u') ?? idFrom('users');
    if (userId != null) return UserRoute(userId);
    final illustId = idFrom('i') ?? idFrom('artworks');
    if (illustId != null) return IllustRoute(illustId);

    // Query parameter fallbacks from beta56.
    final illustIdQuery = uri.queryParameters['illust_id'];
    if (illustIdQuery != null) {
      final id = int.tryParse(illustIdQuery);
      if (id != null && id > 0) return IllustRoute(id);
      return UnknownRoute('invalid illust_id: $illustIdQuery');
    }
    final idQuery = uri.queryParameters['id'];
    if (idQuery != null) {
      final id = int.tryParse(idQuery);
      if (id != null && id > 0) return UserRoute(id);
      return UnknownRoute('invalid id: $idQuery');
    }
    return UnknownRoute('unmapped web path: ${uri.path}');
  }
}
