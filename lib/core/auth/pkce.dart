import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// RFC 7636 PKCE helpers and Pixiv callback parsing.
///
/// Pure Dart, no I/O: every function here is deterministic or uses
/// [Random.secure] and is directly unit-testable.
abstract final class Pkce {
  /// RFC 7636 unreserved characters allowed inside a code verifier.
  static const String verifierCharset =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  static const int verifierLength = 64;

  /// Generates a cryptographically random code verifier.
  static String generateVerifier({Random? random}) {
    final rng = random ?? Random.secure();
    return List.generate(
      verifierLength,
      (_) => verifierCharset[rng.nextInt(verifierCharset.length)],
    ).join();
  }

  /// S256 challenge: base64url(SHA-256(ascii(verifier))) without padding.
  static String computeChallenge(String verifier) {
    return base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
  }
}

/// Result of validating a `pixiv://account?code=...` redirect.
sealed class PixivCallback {
  const PixivCallback();
}

class PixivCallbackCode extends PixivCallback {
  const PixivCallbackCode(this.code, {this.state});

  /// Exactly one non-empty authorization code.
  final String code;

  /// The authorization state, when supplied by the callback. OAuthService
  /// requires it to match the live PKCE session before accepting the code.
  final String? state;
}

class PixivCallbackOther extends PixivCallback {
  const PixivCallbackOther(this.uri);

  /// Any URI that is not a whitelisted account callback. The WebView must
  /// treat this as a normal navigation, never as a completed login.
  final Uri uri;
}

class PixivCallbackInvalid extends PixivCallback {
  const PixivCallbackInvalid(this.uri, this.reason);

  /// A `pixiv://account` URI whose code parameter is missing, empty or
  /// duplicated. Login must fail and the session must be discarded.
  final Uri uri;
  final String reason;
}

/// Parses a `pixiv://account` redirect.
///
/// Pixiv's real callback is `pixiv://account/login?code=...&via=...`: it
/// carries a path and its own extra parameters, and it does not echo `state`.
/// Only the parts that make a code genuinely ambiguous are rejected here; the
/// authorization code is still worthless without this session's PKCE verifier.
PixivCallback parsePixivAccountCallback(Uri uri) {
  if (uri.scheme != 'pixiv' || uri.host != 'account') {
    return PixivCallbackOther(uri);
  }
  final codes = uri.queryParametersAll['code'];
  if (codes == null) {
    return PixivCallbackInvalid(uri, 'missing code');
  }
  if (codes.length > 1) {
    return PixivCallbackInvalid(uri, 'duplicate code');
  }
  final code = codes.single;
  if (code.isEmpty) {
    return PixivCallbackInvalid(uri, 'empty code');
  }
  final states = uri.queryParametersAll['state'];
  if (states != null && states.length > 1) {
    return PixivCallbackInvalid(uri, 'duplicate state');
  }
  return PixivCallbackCode(code, state: states?.single);
}
