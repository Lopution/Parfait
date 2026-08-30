import 'dart:async';

import 'package:flutter/services.dart';

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
    final uri = Uri.parse(urlValue);
    final result = await fetchWithPolicy(uri);
    if (result == null) {
      // Native fallthrough.
      throw PlatformException(code: 'unavailable', message: 'host not allowed');
    }
    return result;
  }

  /// Fetches [uri] via the policy ladder. Returns a Map for PlatformView
  /// conversion or null when the host is not registry-allowed (native must
  /// fall through).
  Future<Map<String, Object?>?> fetchWithPolicy(Uri uri) async {
    final purpose = _purposeForHost(uri.host.toLowerCase());
    if (purpose == null) return null;
    try {
      policy.registry.require(uri, purpose);
    } on PixivDestinationException {
      return null;
    }
    try {
      final client = _policyClient(purpose);
      final response = await client.get(uri);
      final body = response.bodyBytes;
      final headers = <String, String>{};
      response.headers.forEach((name, value) {
        headers[name] = value;
      });
      return {
        'status': response.statusCode,
        'mimeType': response.headers['content-type']?.split(';').first ??
            'application/octet-stream',
        'encoding': 'utf-8',
        'headers': headers,
        'bodyBytes': body.buffer.asUint8List(),
      };
    } on Object catch (error) {
      // Any fetch failure: report back so the native side falls through.
      throw PlatformException(
        code: 'policy_fetch_failed',
        message: '$error',
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
}
