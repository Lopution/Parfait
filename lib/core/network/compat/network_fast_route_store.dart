import 'dart:async';
import 'dart:convert';
import 'dart:developer' show log;
import 'dart:io';

import '../pixiv_client_identity.dart';
import '../../settings/preference_keys.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'route_memory.dart';
import 'secure_resolver.dart';

/// Persists the last known public origin address of the Pixiv image hosts
/// for the `bootstrapNoSni` tier.
///
/// The address map is only a connection bootstrap. The request still carries
/// the canonical Pixiv hostname as Host and verifies its certificate. An
/// address is learned only after a `noSni` request was served from it, so a
/// DoH answer that cannot complete an empty-SNI handshake is never stored.
/// Keeping this tiny cache outside the route-memory TTL means the first
/// request after an app restart does not pay for polluted system DNS.
class PixivFastRouteStore implements FastRouteMemory {
  static const storageKey = PreferenceKeys.fastRoutes;

  /// Built-in origin addresses, exposed read-only so a second
  /// [FastRouteMemory] (the image worker's in-memory store) can seed the
  /// same fallback values without touching SharedPreferences.
  ///
  /// Image hosts only: pixiv's origin answers API, OAuth and web traffic
  /// that bypasses Cloudflare with 403, and their public DNS names resolve
  /// to Cloudflare, which rejects a handshake without SNI. Persisted
  /// entries for any other host are dropped on read.
  static final Map<String, InternetAddress> bootstrap = Map.unmodifiable({
    for (final imageHost in PixivClientIdentity.downloadHosts)
      imageHost: InternetAddress('210.140.139.133'),
  });

  static final Map<String, InternetAddress> _bootstrap = bootstrap;

  final SharedPreferencesAsync _preferences;

  PixivFastRouteStore({required SharedPreferencesAsync preferences})
    : _preferences = preferences;
  Future<Map<String, InternetAddress>>? _loadFuture;
  Future<void> _writeTail = Future<void>.value();

  @override
  Future<InternetAddress?> addressFor(String host) async {
    final persisted = (await _load())[host];
    return persisted ?? _bootstrap[host];
  }

  /// Records a public address after a route has actually served a request.
  /// Writes are serialized because API, OAuth, and image requests can finish
  /// concurrently during startup. Callers do not wait: a failed write is
  /// logged.
  @override
  Future<void> remember(String host, InternetAddress address) {
    if (!isPublicNetworkAddress(address) || !_bootstrap.containsKey(host)) {
      return Future<void>.value();
    }
    return _writeTail = _writeTail.then<void>((_) async {
      final current = await _load();
      if (current[host]?.address == address.address) return;
      current[host] = address;
      try {
        await _preferences.setString(
          storageKey,
          jsonEncode({
            for (final entry in current.entries) entry.key: entry.value.address,
          }),
        );
      } on Object catch (error) {
        log('fast route not remembered: $error');
      }
    });
  }

  /// The persisted addresses, without the bootstrap fallback — the seed of
  /// the image worker's in-memory copy.
  Future<Map<String, InternetAddress>> learned() async => Map.of(await _load());

  Future<Map<String, InternetAddress>> _load() {
    return _loadFuture ??= _read();
  }

  Future<Map<String, InternetAddress>> _read() async {
    try {
      final raw = await _preferences.getString(storageKey);
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
      // bootstrap addresses and is rewritten after the next success.
      return <String, InternetAddress>{};
    }
  }
}
