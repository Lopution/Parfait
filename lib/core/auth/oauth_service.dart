import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../network/pixiv_client_identity.dart';
import '../network/pixiv_headers.dart';
import 'credential.dart';
import 'pkce.dart';

/// Raised when the OAuth token exchange fails or a session is misused.
class OAuthException implements Exception {
  const OAuthException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() =>
      'OAuthException($message${statusCode == null ? '' : ', status: $statusCode'})';
}

/// A single in-flight login attempt.
class PkceSession {
  PkceSession._(this.id, String verifier, this.challenge, this.expiresAt)
      : _verifier = verifier;

  final String id;
  final String challenge;
  final DateTime expiresAt;
  bool consumed = false;
  String? _verifier;

  /// The verifier is empty once the session has been consumed or cleared.
  String get verifier => _verifier ?? '';
  bool get expired => DateTime.now().isAfter(expiresAt);

  /// Irrecoverably clears the single-use secret.
  void clearSecrets() {
    _verifier = null;
  }
}

/// Non-secret user profile returned by a successful token exchange.
class OAuthUserProfile {
  const OAuthUserProfile({
    required this.userId,
    required this.name,
    this.mailAddress,
    this.profileImageUrl,
  });

  final int userId;
  final String name;
  final String? mailAddress;
  final String? profileImageUrl;
}

/// Result of a completed OAuth login.
class OAuthResult {
  const OAuthResult({required this.accountId, required this.credential, required this.profile});

  final String accountId;
  final Credential credential;
  final OAuthUserProfile profile;
}

/// Pixiv OAuth PKCE login: session lifecycle + strict token exchange.
///
/// - Exactly one live session at a time; the verifier is single-use and is
///   cleared on success, failure, cancellation, timeout and dispose.
/// - The token exchange only ever talks to the fixed, verified endpoint
///   configured at construction; no user input ever enters the URL.
/// - TLS is strict: the default http.Client never bypasses certificate
///   validation and this service does not override it.
class OAuthService {
  OAuthService({
    http.Client? client,
    Uri? tokenEndpoint,
    Uri? authorizeEndpoint,
    Duration sessionTtl = defaultSessionTtl,
    Duration exchangeTimeout = defaultExchangeTimeout,
  })  : _client = client ?? http.Client(),
        _tokenEndpoint = tokenEndpoint ?? defaultTokenEndpoint,
        _authorizeEndpoint = authorizeEndpoint ?? defaultAuthorizeEndpoint,
        _sessionTtl = sessionTtl,
        _exchangeTimeout = exchangeTimeout;

  static final Uri defaultAuthorizeEndpoint = PixivClientIdentity.webLoginEndpoint;
  static final Uri defaultTokenEndpoint = PixivClientIdentity.oauthTokenEndpoint;
  static const String defaultRedirectUri = PixivClientIdentity.oauthRedirectUri;
  static const String clientId = PixivClientIdentity.clientId;
  static const String clientSecret = PixivClientIdentity.clientSecret;
  static const Duration defaultSessionTtl = Duration(minutes: 10);
  static const Duration defaultExchangeTimeout = Duration(seconds: 15);

  static const String callbackScheme = 'pixiv';
  static const String callbackHost = 'account';

  final http.Client _client;
  final Uri _tokenEndpoint;
  final Uri _authorizeEndpoint;
  final Duration _sessionTtl;
  final Duration _exchangeTimeout;

  PkceSession? _session;
  int _sessionCounter = 0;

  /// Whether a live (non-expired, unconsumed) session exists.
  bool get hasLiveSession {
    final session = _session;
    return session != null && !session.expired && !session.consumed;
  }

  /// Creates the one-and-only PKCE session and the authorize URL to load.
  ({Uri authorizeUrl, String sessionId}) beginSession() {
    discardSession();
    final verifier = Pkce.generateVerifier();
    final challenge = Pkce.computeChallenge(verifier);
    final session = PkceSession._(
      'pkce-${DateTime.now().microsecondsSinceEpoch}-${_sessionCounter++}',
      verifier,
      challenge,
      DateTime.now().add(_sessionTtl),
    );
    _session = session;
    final url = _authorizeEndpoint.replace(queryParameters: {
      ..._authorizeEndpoint.queryParameters,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'client': 'pixiv-android',
    });
    return (authorizeUrl: url, sessionId: session.id);
  }

  /// Validates a WebView redirect. Returns the code only for a live session
  /// and a whitelisted `pixiv://account?code=...` URI.
  PixivCallback validateRedirect(Uri uri) {
    final parsed = parsePixivAccountCallback(uri);
    if (parsed is! PixivCallbackCode) return parsed;
    final session = _session;
    if (session == null || session.expired || session.consumed) {
      return PixivCallbackInvalid(uri, 'no live session');
    }
    return parsed;
  }

  /// Atomically consumes the live session and exchanges the code for tokens.
  ///
  /// On any failure the session is discarded; the caller cannot retry the
  /// same verifier.
  Future<OAuthResult> exchangeCode(String code) async {
    final session = _session;
    if (session == null || session.expired || session.consumed) {
      discardSession();
      throw OAuthException('no live PKCE session');
    }
    final verifier = session.verifier;
    session.consumed = true;
    _session = null;
    try {
      final response = await _client
          .post(
            _tokenEndpoint,
            headers: PixivHeaders.oauth(),
            body: {
              'client_id': clientId,
              'client_secret': clientSecret,
              'code': code,
              'code_verifier': verifier,
              'grant_type': 'authorization_code',
              'include_policy': 'true',
              'redirect_uri': defaultRedirectUri,
            },
          )
          .timeout(_exchangeTimeout);

      if (response.statusCode != 200) {
        throw OAuthException(
          'token exchange failed',
          statusCode: response.statusCode,
        );
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return _parseTokenResponse(json);
    } on TimeoutException {
      throw OAuthException('token exchange timed out');
    } on SocketException catch (error) {
      throw OAuthException('token exchange network error', cause: error);
    } on FormatException catch (error) {
      throw OAuthException('token response is not valid JSON', cause: error);
    } finally {
      // The verifier never survives an exchange attempt.
      session.clearSecrets();
    }
  }

  /// Clears any live session (user cancelled, page disposed, timeout).
  void discardSession() {
    _session = null;
  }

  /// Refreshes tokens with a refresh token (grant_type=refresh_token).
  ///
  /// Throws [OAuthException] with statusCode 400-class detail when the
  /// refresh token is invalid or expired; callers translate that into the
  /// re-auth flow.
  Future<OAuthResult> refreshSession(String refreshToken) async {
    try {
      final response = await _client
          .post(
            _tokenEndpoint,
            headers: PixivHeaders.oauth(),
            body: {
              'client_id': clientId,
              'client_secret': clientSecret,
              'include_policy': 'true',
              'grant_type': 'refresh_token',
              'refresh_token': refreshToken,
            },
          )
          .timeout(_exchangeTimeout);
      if (response.statusCode != 200) {
        throw OAuthException(
          'token refresh failed',
          statusCode: response.statusCode,
        );
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return _parseTokenResponse(json);
    } on TimeoutException {
      throw const OAuthException('token refresh timed out');
    } on SocketException catch (error) {
      throw OAuthException('token refresh network error', cause: error);
    } on FormatException catch (error) {
      throw OAuthException('token refresh response is not valid JSON',
          cause: error);
    }
  }

  OAuthResult _parseTokenResponse(Map<String, dynamic> json) {
    final accessToken = json['access_token'];
    final refreshToken = json['refresh_token'];
    if (accessToken is! String || refreshToken is! String) {
      throw const OAuthException('token response missing tokens');
    }
    final user = json['user'];
    if (user is! Map<String, dynamic>) {
      throw const OAuthException('token response missing user');
    }
    final userIdRaw = user['id'];
    final userId = userIdRaw is int
        ? userIdRaw
        : userIdRaw is String
            ? int.tryParse(userIdRaw)
            : null;
    final name = user['name'];
    if (userId == null || name is! String) {
      throw const OAuthException('token response user is incomplete');
    }
    final profileImageUrls = user['profile_image_urls'];
    return OAuthResult(
      accountId: '$userId',
      credential: Credential(
        accessToken: accessToken,
        refreshToken: refreshToken,
      ),
      profile: OAuthUserProfile(
        userId: userId,
        name: name,
        mailAddress: user['mail_address'] is String
            ? user['mail_address'] as String
            : null,
        profileImageUrl: profileImageUrls is Map<String, dynamic>
            ? profileImageUrls['main'] as String?
            : null,
      ),
    );
  }
}
