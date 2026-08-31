import 'dart:async';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/network/compat/network_contracts.dart';
import '../../core/network/compat/network_policy.dart';

/// Dart side of the login WebView request interception (PRD R7).
///
/// Native `shouldInterceptRequest` calls `fetchWithPolicy(url)` on this
/// channel; we re-send the request through the SAME [NetworkAccessPolicy]
/// ladder as API / image / download exits, returning status + headers +
/// body. The native side turns that into a `WebResourceResponse` and
/// injects `Set-Cookie` one-by-one into `CookieManager`.
///
/// Guarantees:
/// - The registry still owns the allowlist: only pixiv-owned hosts pass
///   `registry.require`; anything else errors and the native stack falls
///   through (interception never swallows foreign content).
/// - No credentials are attached: the auth session lives in the WebView's
///   cookie jar, not in the Dart client. The Dart request is a bare GET
///   whose only purpose is fetching bytes over the policy-selected tier.
/// - Failures (timeout, channel error, exception) return null via the
///   error path → native stack proceeds.
class LoginWebViewInterceptController {
  LoginWebViewInterceptController(this.policy);

  static const _channelName = 'pixivfunc/login_webview_intercept';
  static const _fetchMethod = 'fetchWithPolicy';

  final NetworkAccessPolicy policy;
  MethodChannel? _channel;

  /// Registers the mock/native channel. Must be called exactly once per app
  /// run (the Android side resolves the same named channel). Returns a
  /// dispose callback.
  void Function() register() {
    assert(_channel == null, 'intercept controller already registered');

    final channel = MethodChannel(_channelName);
    _channel = channel;
    channel.setMethodCallHandler(_handleCall);
    return () {
      channel.setMethodCallHandler(null);
      _channel = null;
    };
  }

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method != _fetchMethod) {
      throw MissingPluginException('${call.method} not implemented');
    }
    final raw = call.arguments as Map<Object?, Object?>?;
    final urlValue = raw?['url'];
    if (urlValue is! String) {
      throw PlatformException(code: 'bad_arguments', message: 'url missing');
    }
    final rawHeaders = raw?['headers'];
    final headers = rawHeaders is Map
        ? rawHeaders.map<String, String>(
            (key, value) => MapEntry(key.toString(), value.toString()),
          )
        : const <String, String>{};
    final uri = Uri.parse(urlValue);
    final result = await fetchWithPolicy(uri, headers: headers);
    if (result == null) {
      // Native fallthrough.
      throw PlatformException(code: 'unavailable', message: 'host not allowed');
    }
    return result;
  }

  /// Fetches [uri] via the policy ladder. Returns a Map for PlatformView
  /// conversion or null when the host is not registry-allowed (native must
  /// fall through).
  Future<Map<String, Object?>?> fetchWithPolicy(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    final purpose = _purposeForHost(uri.host.toLowerCase());
    if (purpose == null) return null;
    try {
      policy.registry.require(uri, purpose);
    } on PixivDestinationException {
      return null;
    }
    try {
      final client = _policyClient(purpose);
      final request = http.Request('GET', uri)
        ..headers.addAll(_forwardableHeaders(headers));
      final response = await http.Response.fromStream(
        await client.send(request),
      );
      final body = response.bodyBytes;
      final responseHeaders = <String, String>{};
      final setCookies = <String>[];
      response.headers.forEach((name, value) {
        responseHeaders[name] = value;
        if (name.toLowerCase() == 'set-cookie') {
          setCookies.addAll(_splitSetCookieHeader(value));
        }
      });
      return {
        'status': response.statusCode,
        'mimeType':
            response.headers['content-type']?.split(';').first ??
            'application/octet-stream',
        'encoding': 'utf-8',
        'headers': responseHeaders,
        // package:http exposes combined header values. Keep an explicit list
        // for the Android PlatformView so multiple Set-Cookie lines survive
        // the channel boundary and are injected one by one.
        'setCookies': setCookies,
        'bodyBytes': body.buffer.asUint8List(),
      };
    } on Object catch (error) {
      // Any fetch failure: report back so the native side falls through.
      // Do not put the intercepted URL (which may carry an OAuth query) into
      // a platform-channel error string or log sink.
      throw PlatformException(
        code: 'policy_fetch_failed',
        message: error.runtimeType.toString(),
      );
    }
  }

  /// Maps a WebView host to the policy purpose the registry expects. The
  /// login flow touches API, OAuth and web hosts; each purpose has its own
  /// allowlist entry (the registry enforces exact-host separation). Hosts
  /// outside the registry (captcha vendors, identity providers) return null
  /// and native falls through.
  static PixivDestinationPurpose? _purposeForHost(String host) {
    return switch (host) {
      'app-api.pixiv.net' => PixivDestinationPurpose.appApi,
      'oauth.secure.pixiv.net' => PixivDestinationPurpose.oauth,
      'accounts.pixiv.net' => PixivDestinationPurpose.accountsWeb,
      'www.pixiv.net' => PixivDestinationPurpose.pixivWeb,
      'i.pximg.net' || 's.pximg.net' => PixivDestinationPurpose.image,
      _ => null,
    };
  }

  PixivPolicyHttpClient _policyClient(PixivDestinationPurpose purpose) {
    // One client per purpose: the policy pools clients per route+host and
    // the ladder's role is to pick a tier per request — the policy client
    // does that through PixivPolicyHttpClient.send → runLadder.
    return _clients.putIfAbsent(
      purpose,
      () => PixivPolicyHttpClient(policy: policy, purpose: purpose),
    );
  }

  final Map<PixivDestinationPurpose, PixivPolicyHttpClient> _clients = {};

  /// Preserve browser-session headers needed by an intercepted GET while
  /// excluding authority/authentication headers that the policy transport
  /// must own. In particular, Cookie is intentionally forwarded from the
  /// WebView jar; Authorization is never accepted from the channel payload.
  static Map<String, String> _forwardableHeaders(Map<String, String> headers) {
    const allowed = {
      'accept',
      'accept-language',
      'cache-control',
      'cookie',
      'referer',
      'user-agent',
    };
    return {
      for (final entry in headers.entries)
        if (allowed.contains(entry.key.toLowerCase()))
          entry.key.toLowerCase(): entry.value,
    };
  }

  static List<String> _splitSetCookieHeader(String value) {
    final result = <String>[];
    var start = 0;
    var inExpires = false;
    for (var i = 0; i < value.length; i++) {
      final lower = value.substring(i).toLowerCase();
      if (lower.startsWith('expires=')) inExpires = true;
      if (value[i] == ';') inExpires = false;
      if (value[i] != ',' || inExpires) continue;
      final candidate = value.substring(i + 1).trimLeft();
      final equals = candidate.indexOf('=');
      final semicolon = candidate.indexOf(';');
      if (equals > 0 && (semicolon < 0 || equals < semicolon)) {
        final cookie = value.substring(start, i).trim();
        if (cookie.isNotEmpty) result.add(cookie);
        start = i + 1;
      }
    }
    final last = value.substring(start).trim();
    if (last.isNotEmpty) result.add(last);
    return result;
  }
}
