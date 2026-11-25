import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/dev_webview_environment.dart';
import '../platform/platform_caps.dart';

/// Platform bridge for the shared WebView session cookie (web profile).
abstract class WebProfileSession {
  Future<String?> readSessionCookie();
  Future<bool> clearSession();
  Future<bool> clearPixivAuthSession();
}

class MethodChannelWebProfileSession implements WebProfileSession {
  const MethodChannelWebProfileSession([
    this._channel = const MethodChannel(_WebProfileMethods.channel),
    this._caps = const PlatformCaps(),
  ]);

  final MethodChannel _channel;
  final PlatformCaps _caps;

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
    var cleared = false;
    if (_caps.isAndroid) {
      try {
        cleared =
            await _channel.invokeMethod<bool>(
              _WebProfileMethods.clearSession,
            ) ??
            false;
      } on MissingPluginException {
        // Non-Android platforms clear through flutter_inappwebview below.
      } on PlatformException {
        // Report false so logout/switch can continue.
      }
    }
    if (!_canTouchWebViewStorage()) return cleared;
    final env = DevWebViewEnvironmentHolder.resolveForWebView(
      isWindowsOverride: _caps.isWindows,
    );
    try {
      await CookieManager.instance(webViewEnvironment: env).deleteAllCookies();
      cleared = true;
    } on Object {
      // Non-fatal: missing WebView runtime must not block account transitions.
    }
    if (env == null) {
      try {
        await WebStorageManager.instance().deleteAllData();
      } on Object {
        // Best-effort storage wipe.
      }
    }
    return cleared;
  }

  @override
  Future<bool> clearPixivAuthSession() async {
    if (!_canTouchWebViewStorage()) return false;
    final env = DevWebViewEnvironmentHolder.resolveForWebView(
      isWindowsOverride: _caps.isWindows,
    );
    final manager = CookieManager.instance(webViewEnvironment: env);
    var cleared = false;
    for (final rawUrl in const [
      'https://accounts.pixiv.net',
      'https://www.pixiv.net',
    ]) {
      try {
        await manager.deleteCookies(url: WebUri(rawUrl));
        cleared = true;
      } on Object {
        // Best-effort per host.
      }
    }
    try {
      await manager.deleteCookies(
        url: WebUri('https://www.pixiv.net'),
        domain: '.pixiv.net',
      );
      cleared = true;
    } on Object {
      // Best-effort domain cookie cleanup.
    }
    return cleared;
  }

  bool _canTouchWebViewStorage() {
    if (!_caps.supportsInAppWebView) return false;
    if (_caps.isWindows &&
        DevWebViewEnvironmentHolder.isUnavailableInDevWindows()) {
      return false;
    }
    return true;
  }
}

final webProfileSessionProvider = Provider<WebProfileSession>((ref) {
  return MethodChannelWebProfileSession(
    const MethodChannel(_WebProfileMethods.channel),
    ref.watch(platformCapsProvider),
  );
});

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
