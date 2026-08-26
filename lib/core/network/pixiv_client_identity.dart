/// Centralized, immutable Pixiv client identity.
///
/// Every time-sensitive constant lives here with its provenance
/// (`.trellis/tasks/08-26-pixiv-network-token-refresh/research/`).
/// Feature code must never keep copies of these values.
abstract final class PixivClientIdentity {
  /// Public OAuth client id embedded in all OSS Pixiv clients.
  static const String clientId = 'MOBrBDS8blbauoSck0ZfDbtuzpyT';

  /// Public OAuth client secret embedded in all OSS Pixiv clients.
  static const String clientSecret =
      'lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj';

  /// App API base (illusts, users, search, ...).
  static final Uri appApiBase = Uri(scheme: 'https', host: 'app-api.pixiv.net');

  /// OAuth token endpoint host.
  static const String oauthHost = 'oauth.secure.pixiv.net';

  /// OAuth token endpoint.
  static final Uri oauthTokenEndpoint = Uri(
    scheme: 'https',
    host: oauthHost,
    path: '/auth/token',
  );

  /// Redirect URI used by the Pixiv android client during code exchange.
  static const String oauthRedirectUri =
      'https://app-api.pixiv.net/web/v1/users/auth/pixiv/callback';

  /// Web login page hosting the PKCE challenge (authorize entry).
  static final Uri webLoginEndpoint =
      Uri(scheme: 'https', host: 'app-api.pixiv.net', path: 'web/v1/login');

  /// Android client identity sent with API and OAuth requests.
  static const String appOs = 'android';
  static const String appOsVersion = '11.0';
  static const String appVersion = '5.0.234';
  static const String deviceModel = 'Pixel 5';

  static String get userAgent =>
      'PixivAndroidApp/$appVersion (Android $appOsVersion; $deviceModel)';

  /// Hosts allowed for API navigation (next_url parsing).
  static const Set<String> apiHosts = {'app-api.pixiv.net'};

  /// Hosts allowed for OAuth operations.
  static const Set<String> oauthHosts = {oauthHost};
}
