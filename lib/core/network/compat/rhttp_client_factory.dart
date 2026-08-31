import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart' as rhttp;

import 'network_contracts.dart';

/// Maps a [NetworkRoute] to an rhttp (Rust reqwest + rustls) client.
///
/// This is the transport replacement point (design.md §接缝): one factory
/// takes the only functional decision — which DNS source, which TLS
/// presentation, whether certificate verification stays on, and how long the
/// tier may spend before the ladder moves on — for a given tier. rhttp
/// compiles the platform roots via `rustls_platform_verifier` when
/// `RootCertSource.platform` is used; we keep webpki (bundled Mozilla roots)
/// for determinism.
///
/// Every client is created via `RhttpCompatibleClient.createSync`, which
/// matches the synchronous `NetworkClientFactory` signature. The Rust side
/// is stateless per client: no DNS resolution, no ECH discovery, no TTL
/// cache — all of that stays in `DohResolver` / `NetworkAccessPolicy`.
abstract final class RhttpClientFactory {
  /// Connection budget for the `direct` tier.
  ///
  /// Inside the wall `direct` is a guaranteed loss: system DNS answers for
  /// pixiv hosts are polluted, so the attempt either blackholes or the
  /// real-SNI handshake is reset. It must fail fast enough that the ladder
  /// still has room for the tiers that can actually succeed. Outside the wall
  /// it connects in well under a second, so a short budget costs nothing.
  ///
  /// Measured on a mainland device (2026-08-30): with no timeout configured
  /// at all, the direct attempt hung on a polluted address until the API
  /// client's outer 20s budget fired, and the `ech` / `dohRealSni` tiers were
  /// never reached — confirmed by packet capture (only one plaintext UDP DNS
  /// query on the wire, zero DoH/ECH connections).
  static const directConnectTimeout = Duration(seconds: 3);

  /// Connection budget for the fallback tiers (ech / dohRealSni / noSni…).
  ///
  /// Larger than [directConnectTimeout] because these are the paths expected
  /// to succeed; on the same mainland device the ECH front handshake
  /// completed in ~0.54s and DoH answered in ~0.11s.
  static const fallbackConnectTimeout = Duration(seconds: 4);

  /// Total budget for the `direct` tier on non-streaming exits.
  static const directRequestTimeout = Duration(seconds: 5);

  /// Total budget for a fallback tier on non-streaming exits.
  ///
  /// The ladder runs at most three tiers within the API client's single
  /// [PixivHttpClient.defaultRequestTimeout] (20s) budget, so the worst case
  /// is [directRequestTimeout] + 2 × [fallbackRequestTimeout] = 19s and the
  /// outer timeout stays the backstop it was meant to be rather than the
  /// thing that fires first.
  static const fallbackRequestTimeout = Duration(seconds: 7);

  /// Builds one pooled client for [route]. [canonicalHost] is the canonical
  /// Pixiv host from the registry; it is what the request URL carries (and
  /// therefore what SNI / Host / certificate hostname verification use).
  ///
  /// [purpose] selects the time budget shape: image and download exits stream
  /// their body, so they get a connect budget only.
  static http.Client create(
    NetworkRoute route,
    String canonicalHost,
    PixivDestinationPurpose purpose,
  ) {
    return rhttp.RhttpCompatibleClient.createSync(
      settings: settingsFor(
        route,
        destinationHost: canonicalHost,
        purpose: purpose,
      ),
    );
  }

  /// The rhttp [rhttp.ClientSettings] for [route]. Pure mapping; unit-tested
  /// offline without touching native FFI.
  static rhttp.ClientSettings settingsFor(
    NetworkRoute route, {
    required String destinationHost,
    required PixivDestinationPurpose purpose,
  }) {
    _checkRoute(route);
    final tls = rhttp.TlsSettings(
      // TLS 1.3 is required by ECH; leave the rest at rustls defaults.
      sni: route.presentsRealSni,
      verifyCertificates: route.verifiesCertificates,
      echConfigList: route.kind == NetworkRouteKind.ech
          ? Uint8List.fromList(route.echConfig!)
          : null,
    );
    final address = route.address;
    final dns = address == null
        ? const rhttp.DnsSettings.static()
        : rhttp.DnsSettings.static(
            overrides: {
              destinationHost: [address.address],
            },
          );
    return rhttp.ClientSettings(
      // Let rustls/reqwest negotiate HTTP/2 or HTTP/1.1 via ALPN.  Forcing
      // `prior_knowledge` HTTP/2 breaks perfectly valid Pixiv edges that do
      // not advertise h2; HTTP/3 remains disabled because `all` in this
      // fork means the TLS ALPN pair only.
      httpVersionPref: rhttp.HttpVersionPref.all,
      redirectSettings: const rhttp.RedirectSettings.none(),
      timeoutSettings: timeoutsFor(route, purpose: purpose),
      tlsSettings: tls,
      dnsSettings: dns,
    );
  }

  /// The time budget for [route] on a [purpose] exit.
  ///
  /// Streaming exits (images, downloads) get **no** total timeout: rhttp's
  /// `timeout` covers the whole request including the body, so setting it
  /// would abort a large transfer mid-download. Their protection is the
  /// connect budget plus the ladder's own failure classification.
  static rhttp.TimeoutSettings timeoutsFor(
    NetworkRoute route, {
    required PixivDestinationPurpose purpose,
  }) {
    final isDirect = route.kind == NetworkRouteKind.direct;
    return rhttp.TimeoutSettings(
      connectTimeout: isDirect ? directConnectTimeout : fallbackConnectTimeout,
      timeout: _isStreaming(purpose)
          ? null
          : (isDirect ? directRequestTimeout : fallbackRequestTimeout),
    );
  }

  /// Whether the exit streams a response body whose size is unbounded.
  static bool _isStreaming(PixivDestinationPurpose purpose) =>
      purpose == PixivDestinationPurpose.image;

  static void _checkRoute(NetworkRoute route) {
    if (route.kind == NetworkRouteKind.ech &&
        (route.echConfig == null || route.echConfig!.isEmpty)) {
      throw ArgumentError('ECH route without usable echConfig');
    }
    if (route.kind != NetworkRouteKind.direct && route.address == null) {
      throw ArgumentError('strict route must carry a connect address');
    }
    if (route.kind == NetworkRouteKind.direct && route.address != null) {
      throw ArgumentError('direct route must not carry an address');
    }
  }
}
