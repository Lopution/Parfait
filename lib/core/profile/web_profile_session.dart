import 'package:flutter/services.dart';

/// Platform bridge for the shared WebView session cookie (web profile).
abstract class WebProfileSession {
  Future<String?> readSessionCookie();
  Future<bool> clearSession();
}

class MethodChannelWebProfileSession implements WebProfileSession {
  const MethodChannelWebProfileSession([
    this._channel = const MethodChannel(_WebProfileMethods.channel),
  ]);

  final MethodChannel _channel;

  @override
  Future<String?> readSessionCookie() async {
    try {
      return await _channel.invokeMethod<String>(
        _WebProfileMethods.readSession,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      // Any `webprofile_<reason>` (read/clear/permission/io) is treated as
      // no session — the profile editor falls back to unavailable.
      return null;
    }
  }

  @override
  Future<bool> clearSession() async {
    try {
      return await _channel.invokeMethod<bool>(
            _WebProfileMethods.clearSession,
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      // Same family as [readSessionCookie]: every native code is "cleared
      // failed" → report false so logout can continue.
      return false;
    }
  }
}

abstract final class _WebProfileMethods {
  static const channel = 'parfait/webprofile';
  static const readSession = 'readSession';
  static const clearSession = 'clearSession';
}

/// The pixiv user the shared cookie header is signed in as, or null.
///
/// A signed-in pixiv web session is `PHPSESSID=<uid>_<hash>`; an anonymous
/// one (the login page hands one out before sign-in) is bare hex. The
/// header is sent as it is, so it counts only when it carries exactly one
/// distinct PHPSESSID and that one is signed in: with two, the server may
/// read the other.
int? webSessionUserId(String? cookie) {
  if (cookie == null) return null;
  final sessions = <String>{
    for (final part in cookie.split(';'))
      if (_cookieName(part) == 'phpsessid')
        part.substring(part.indexOf('=') + 1).trim(),
  };
  if (sessions.length != 1) return null;
  final match = _signedInSession.firstMatch(sessions.single);
  final userId = match == null ? null : int.tryParse(match.group(1)!);
  return userId != null && userId > 0 ? userId : null;
}

final _signedInSession = RegExp(r'^(\d+)_.+$');

String? _cookieName(String part) {
  final separator = part.indexOf('=');
  return separator <= 0
      ? null
      : part.substring(0, separator).trim().toLowerCase();
}
