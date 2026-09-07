import 'package:flutter/services.dart';

/// Platform bridge for the shared WebView session cookie (web profile).
abstract class WebProfileSession {
  Future<String?> readSessionCookie();
  Future<bool> clearSession();
}

class MethodChannelWebProfileSession implements WebProfileSession {
  const MethodChannelWebProfileSession([
    this._channel = const MethodChannel(WebProfileMethods.channel),
  ]);

  final MethodChannel _channel;

  @override
  Future<String?> readSessionCookie() async {
    try {
      return await _channel.invokeMethod<String>(WebProfileMethods.readSession);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<bool> clearSession() async {
    try {
      return await _channel.invokeMethod<bool>(
            WebProfileMethods.clearSession,
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

abstract final class WebProfileMethods {
  static const channel = 'pixivfunc/webprofile';
  static const readSession = 'readSession';
  static const clearSession = 'clearSession';
}

/// True when the shared cookie header carries a non-empty PHPSESSID. The
/// profile API requires that web session; a device_token alone (older mobile
/// web) is not sufficient.
bool hasWebProfileSession(String? cookie) {
  if (cookie == null || cookie.trim().isEmpty) return false;
  for (final part in cookie.split(';')) {
    final separator = part.indexOf('=');
    if (separator <= 0) continue;
    final name = part.substring(0, separator).trim().toLowerCase();
    final value = part.substring(separator + 1).trim();
    if (name == 'phpsessid' && value.isNotEmpty) return true;
  }
  return false;
}
