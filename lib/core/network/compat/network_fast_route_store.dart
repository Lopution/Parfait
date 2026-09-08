import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../pixiv_client_identity.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'network_contracts.dart';
import 'secure_resolver.dart';

/// Persists the last known public address for the Pixiv hosts that PixEz uses
/// for its compatibility transport.
///
/// The address map is only a connection bootstrap. The request still carries
/// the canonical Pixiv hostname as Host, and a successful request refreshes
/// the map from DoH in the background. Keeping this tiny cache outside the
/// route-memory TTL means the first request after an app restart does not pay
/// for polluted system DNS or a route probe.
class PixivFastRouteStore {
  PixivFastRouteStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences;

  static const storageKey = 'pixiv.network.fast_routes.v1';

  /// PixEz's compatibility bootstrap addresses. They are fallback values only
  /// and are replaced by a successful DoH refresh when the network permits it.
  static final Map<String, InternetAddress> _bootstrap = {
    PixivClientIdentity.appApiBase.host: InternetAddress('210.140.139.155'),
    PixivClientIdentity.oauthHost: InternetAddress('210.140.139.155'),
    // The web profile editor uses the same Pixiv/Cloudflare compatibility
    // exit as the API. Keeping this host in the shared store avoids falling
    // back to a polluted system-DNS request before the SPA save call.
    PixivClientIdentity.webHost: InternetAddress('104.18.42.239'),
    for (final imageHost in PixivClientIdentity.downloadHosts)
      imageHost: InternetAddress('210.140.139.133'),
  };

  SharedPreferencesAsync? _preferences;

  SharedPreferencesAsync get _prefs =>
      _preferences ??= SharedPreferencesAsync();
  Future<Map<String, InternetAddress>>? _loadFuture;
  Future<void> _writeTail = Future<void>.value();
  final Set<String> _refreshing = <String>{};

  Future<InternetAddress?> addressFor(String host) async {
    final persisted = (await _load())[host];
    return persisted ?? _bootstrap[host];
  }

  /// Records a public address after a route has actually served a request.
  /// Writes are serialized because API, OAuth, and image requests can finish
  /// concurrently during startup.
  Future<void> remember(String host, InternetAddress address) {
    if (!isPublicNetworkAddress(address) || !_bootstrap.containsKey(host)) {
      return Future<void>.value();
    }
    final operation = _writeTail.then<void>((_) async {
      final current = await _load();
      if (current[host]?.address == address.address) return;
      current[host] = address;
      await _prefs.setString(
        storageKey,
        jsonEncode({
          for (final entry in current.entries) entry.key: entry.value.address,
        }),
      );
    });
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  /// Refreshes one host at most once concurrently. This is intentionally
  /// best-effort: an unavailable DoH endpoint must not delay or fail the
  /// already successful business request.
  Future<void> refresh(
    String host, {
    required SecureResolver resolver,
    required NetworkRevision revision,
  }) async {
    if (resolver is! DohResolver || !_refreshing.add(host)) return;
    try {
      final resolved = await resolver.resolve(host, revision: revision);
      final address = resolved.addresses
          .where(isPublicNetworkAddress)
          .firstOrNull;
      if (address != null) await remember(host, address);
    } on Object {
      // The cache is an acceleration layer. The active route remains valid
      // when a background refresh is unavailable.
    } finally {
      _refreshing.remove(host);
    }
  }

  Future<Map<String, InternetAddress>> _load() {
    return _loadFuture ??= _read();
  }

  Future<Map<String, InternetAddress>> _read() async {
    try {
      final raw = await _prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return <String, InternetAddress>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return <String, InternetAddress>{};
      }
      final result = <String, InternetAddress>{};
      for (final entry in decoded.entries) {
        final host = entry.key;
        final value = entry.value;
        if (!_bootstrap.containsKey(host) || value is! String) continue;
        final address = InternetAddress.tryParse(value);
        if (address != null && isPublicNetworkAddress(address)) {
          result[host] = address;
        }
      }
      return result;
    } on Object {
      // A damaged or unavailable non-secret cache falls back to the bundled
      // PixEz bootstrap addresses and is rewritten after the next success.
      return <String, InternetAddress>{};
    }
  }
}
