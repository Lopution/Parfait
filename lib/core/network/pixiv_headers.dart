import 'pixiv_client_identity.dart';

/// Builds the request headers for Pixiv API/OAuth traffic.
///
/// Header composition is centralized so features never splice identity
/// constants themselves.
abstract final class PixivHeaders {
  /// Standard App API headers, including the bearer token when authenticated.
  static Map<String, String> api({String? languageTag, String? accessToken}) {
    return {
      'User-Agent': PixivClientIdentity.userAgent,
      'App-OS': PixivClientIdentity.appOs,
      'App-OS-Version': PixivClientIdentity.appOsVersion,
      'App-Version': PixivClientIdentity.appVersion,
      'Accept-Language': languageTag ?? 'zh-CN',
      if (accessToken != null) 'Authorization': 'Bearer $accessToken',
    };
  }

  /// OAuth token endpoint headers (never carries a bearer token).
  static Map<String, String> oauth({String? languageTag}) {
    return {
      'User-Agent': PixivClientIdentity.userAgent,
      'App-OS': PixivClientIdentity.appOs,
      'App-OS-Version': PixivClientIdentity.appOsVersion,
      'App-Version': PixivClientIdentity.appVersion,
      'Accept-Language': languageTag ?? 'zh-CN',
    };
  }

  /// Content type for OAuth form posts.
  static const String oauthFormContentType =
      'application/x-www-form-urlencoded';
}
