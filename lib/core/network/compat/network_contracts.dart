import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart' as rhttp;

import '../api_error.dart';

/// The small cancellation contract shared by API, resolver and media paths.
/// It deliberately carries no request data and can therefore be passed across
/// the network layers without widening the logging surface.
abstract interface class NetworkCancelSignal {
  bool get isCancelled;

  Future<void> get whenCancel;
}

/// A destination purpose is part of the allowlist decision. A host being
/// trusted for images must not implicitly make it trusted for OAuth or web
/// navigation.
enum PixivDestinationPurpose { appApi, oauth, accountsWeb, pixivWeb, image }

/// The only origins the app may contact through its Pixiv compatibility
/// policy. Host matching is exact after lowercase canonicalization; suffixes,
/// IP literals, userinfo, fragments and non-443 ports are rejected.
class PixivDestinationRegistry {
  PixivDestination? resolve(Uri uri, PixivDestinationPurpose purpose) {
    final host = _canonicalHost(uri);
    if (host == null || !_allows(host, purpose)) return null;
    return PixivDestination(uri: uri, canonicalHost: host, purpose: purpose);
  }

  PixivDestination require(Uri uri, PixivDestinationPurpose purpose) {
    final destination = resolve(uri, purpose);
    if (destination != null) return destination;
    throw PixivDestinationException(purpose);
  }

  static String? _canonicalHost(Uri uri) {
    if (uri.scheme.toLowerCase() != 'https') return null;
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
      return null;
    }
    if (uri.hasPort && uri.port != 443) return null;
    final host = uri.host.toLowerCase();
    if (host.endsWith('.') || host.codeUnits.any((value) => value > 0x7f)) {
      return null;
    }
    if (InternetAddress.tryParse(host) != null) return null;
    return host;
  }

  static bool _allows(String host, PixivDestinationPurpose purpose) {
    return switch (purpose) {
      PixivDestinationPurpose.appApi => host == 'app-api.pixiv.net',
      PixivDestinationPurpose.oauth => host == 'oauth.secure.pixiv.net',
      PixivDestinationPurpose.accountsWeb =>
        host == 'app-api.pixiv.net' || host == 'accounts.pixiv.net',
      PixivDestinationPurpose.pixivWeb => host == 'www.pixiv.net',
      PixivDestinationPurpose.image =>
        host == 'i.pximg.net' || host == 's.pximg.net',
    };
  }
}

class PixivDestination {
  const PixivDestination({
    required this.uri,
    required this.canonicalHost,
    required this.purpose,
  });

  final Uri uri;
  final String canonicalHost;
  final PixivDestinationPurpose purpose;
}

class PixivDestinationException implements Exception {
  const PixivDestinationException(this.purpose);

  final PixivDestinationPurpose purpose;

  @override
  String toString() =>
      'PixivDestinationException: destination not allowed for '
      '$purpose';
}

enum NetworkMode { automatic, directOnly }

/// The policy tiers. Each tier = DNS source × TLS presentation × certificate
/// verification. Ordering in a ladder is per-destination-group, not global
/// (API hosts are on Cloudflare anycast, image hosts on the origin).
///
/// - [direct]: system DNS + real SNI + full verification (baseline)
/// - [ech]: DoH addresses + ECH (real SNI encrypted, outer = ECH front) +
///   full verification
/// - [dohRealSni]: DoH addresses + real SNI + full verification
/// - [noSni]: DoH/fallback addresses + empty SNI + full verification
///   (origin hosts only: nginx routes by Host without SNI)
/// - [insecureNoSni]: same as [noSni] but certificate verification OFF —
///   ONLY present when the user explicitly enables it; never automatic.
///
/// `certificateMismatch` stays terminal on every tier; the insecure tier is
/// a user-gated escape hatch, not a ladder rung.
enum NetworkRouteKind { direct, ech, dohRealSni, noSni, insecureNoSni }

enum NetworkIpFamily { ipv4, ipv6, unknown }

enum DnsSource { none, system, doh }

enum NetworkFailureKind {
  dns,
  connect,
  timeout,
  reset,
  tlsHandshake,
  certificateMismatch,
  cancelled,
  http,
  auth,
  rateLimit,
  parse,
  redirect,
  unknown,
}

/// A monotonically increasing identity for socket/DNS pools. A network
/// handover or mode change must never reuse a pool created for an old value.
class NetworkRevision {
  const NetworkRevision(this.value, {this.networkIdentity = 'initial'});

  final int value;
  final String networkIdentity;

  @override
  String toString() => '$value/$networkIdentity';
}

class NetworkRoute {
  NetworkRoute._({
    required this.kind,
    required this.revision,
    this.address,
    this.dnsSource = DnsSource.none,
    this.ttl,
    List<int>? echConfig,
  }) : echConfig = echConfig == null ? null : List<int>.unmodifiable(echConfig);

  factory NetworkRoute.direct(NetworkRevision revision) =>
      NetworkRoute._(kind: NetworkRouteKind.direct, revision: revision);

  factory NetworkRoute.secureDns(
    NetworkRevision revision,
    InternetAddress address, {
    DnsSource dnsSource = DnsSource.system,
    Duration? ttl,
  }) => NetworkRoute._(
    kind: NetworkRouteKind.dohRealSni,
    revision: revision,
    address: address,
    dnsSource: dnsSource,
    ttl: ttl,
  );

  /// ECH tier: DoH-resolved address + ECH config bytes.
  factory NetworkRoute.ech(
    NetworkRevision revision,
    InternetAddress address,
    List<int> echConfig, {
    DnsSource dnsSource = DnsSource.doh,
    Duration? ttl,
  }) {
    if (echConfig.isEmpty ||
        echConfig.any((value) => value < 0 || value > 255)) {
      throw ArgumentError.value(echConfig, 'echConfig', 'must contain bytes');
    }
    return NetworkRoute._(
      kind: NetworkRouteKind.ech,
      revision: revision,
      address: address,
      dnsSource: dnsSource,
      ttl: ttl,
      echConfig: echConfig,
    );
  }

  /// No-SNI tier for origin hosts (empty SNI + full verification).
  factory NetworkRoute.noSni(
    NetworkRevision revision,
    InternetAddress address, {
    DnsSource dnsSource = DnsSource.doh,
    Duration? ttl,
  }) => NetworkRoute._(
    kind: NetworkRouteKind.noSni,
    revision: revision,
    address: address,
    dnsSource: dnsSource,
    ttl: ttl,
  );

  /// User-gated insecure fallback: empty SNI + NO certificate verification.
  factory NetworkRoute.insecureNoSni(
    NetworkRevision revision,
    InternetAddress address, {
    DnsSource dnsSource = DnsSource.doh,
    Duration? ttl,
  }) => NetworkRoute._(
    kind: NetworkRouteKind.insecureNoSni,
    revision: revision,
    address: address,
    dnsSource: dnsSource,
    ttl: ttl,
  );

  /// Rebuilds this route under a new revision keeping kind/address/dns.
  /// Used by the per-host route memory to reconstruct a fresh route.
  factory NetworkRoute.remembered(
    NetworkRevision revision,
    NetworkRouteKind kind,
    InternetAddress? address, {
    DnsSource dnsSource = DnsSource.doh,
    Duration? ttl,
    List<int>? echConfig,
  }) {
    if (kind == NetworkRouteKind.ech &&
        (echConfig == null ||
            echConfig.isEmpty ||
            echConfig.any((value) => value < 0 || value > 255))) {
      throw ArgumentError.value(echConfig, 'echConfig', 'must contain bytes');
    }
    return NetworkRoute._(
      kind: kind,
      revision: revision,
      address: address,
      dnsSource: dnsSource,
      ttl: ttl,
      echConfig: echConfig,
    );
  }

  final NetworkRouteKind kind;
  final NetworkRevision revision;
  final InternetAddress? address;
  final DnsSource dnsSource;
  final Duration? ttl;

  /// ECH config list bytes for the [NetworkRouteKind.ech] tier.
  final List<int>? echConfig;

  NetworkIpFamily get ipFamily => switch (address?.type) {
    InternetAddressType.IPv4 => NetworkIpFamily.ipv4,
    InternetAddressType.IPv6 => NetworkIpFamily.ipv6,
    _ => NetworkIpFamily.unknown,
  };

  /// Whether this tier presents a real SNI in the ClientHello.
  // ignore: avoid_positional_boolean_parameters
  bool get presentsRealSni => switch (kind) {
    NetworkRouteKind.direct || NetworkRouteKind.dohRealSni => true,
    NetworkRouteKind.ech => true, // encrypted by ECH, outer is the front
    NetworkRouteKind.noSni || NetworkRouteKind.insecureNoSni => false,
  };

  bool get verifiesCertificates => kind != NetworkRouteKind.insecureNoSni;

  String get key => [
    revision.value,
    revision.networkIdentity,
    kind.name,
    ipFamily.name,
    dnsSource.name,
    address?.address ?? '',
    // The ECH config is part of the TLS ClientHello.  Length alone is not a
    // route identity: two rotations can have the same length while carrying
    // different keys/config ids, and reusing the pooled client would then
    // send an old config.  This is bounded by the resolver's response cap.
    echConfig == null
        ? '-'
        : echConfig!
              .map((value) => value.toRadixString(16).padLeft(2, '0'))
              .join(),
  ].join('|');
}

class NetworkFailure {
  const NetworkFailure(this.kind, {this.cause});

  final NetworkFailureKind kind;
  final Object? cause;

  @override
  String toString() => 'NetworkFailure(${kind.name})';
}

/// Deterministic failure used by policy tests and platform adapters. It has
/// no URL/body fields so it cannot accidentally become a credential log sink.
class NetworkFailureException implements Exception {
  const NetworkFailureException(this.kind);

  final NetworkFailureKind kind;

  @override
  String toString() => 'NetworkFailureException(${kind.name})';
}

class NetworkRedirectException implements Exception {
  const NetworkRedirectException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'NetworkRedirectException(HTTP $statusCode)';
}

/// A connectivity probe reached a server but the route cannot be used for
/// this host (currently HTTP 421 is the important case).  It is deliberately
/// distinct from a business HTTP response: route selection may try another
/// transport, while the same status returned by a real API request remains a
/// normal application-layer response.
class NetworkRouteProbeException implements Exception {
  const NetworkRouteProbeException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'NetworkRouteProbeException(HTTP $statusCode)';
}

/// Converts low-level errors into a stable taxonomy. Only the four transport
/// failures listed by [isFallbackEligible] may try a second strict route.
abstract final class TransportFailureClassifier {
  static NetworkFailure classify(Object error) {
    if (error is NetworkFailureException) {
      return NetworkFailure(error.kind, cause: error);
    }
    if (error is ApiNetworkError) return classify(error.cause);
    if (error is ApiTimeout || error is TimeoutException) {
      return NetworkFailure(NetworkFailureKind.timeout, cause: error);
    }
    if (error is ApiCancelled) {
      return NetworkFailure(NetworkFailureKind.cancelled, cause: error);
    }
    if (error is ApiUnauthorized) {
      return NetworkFailure(NetworkFailureKind.auth, cause: error);
    }
    if (error is ApiRateLimited) {
      return NetworkFailure(NetworkFailureKind.rateLimit, cause: error);
    }
    if (error is ApiParseError) {
      return NetworkFailure(NetworkFailureKind.parse, cause: error);
    }
    if (error is ApiHttpError) {
      return NetworkFailure(NetworkFailureKind.http, cause: error);
    }
    if (error is NetworkRouteProbeException) {
      return NetworkFailure(NetworkFailureKind.http, cause: error);
    }
    if (error is NetworkRedirectException) {
      return NetworkFailure(NetworkFailureKind.redirect, cause: error);
    }
    // rhttp wraps its Rust error in package:http's ClientException.  Always
    // unwrap it before looking at the legacy Dart exception hierarchy so a
    // certificate failure cannot be mistaken for a generic connection error.
    if (error is rhttp.RhttpWrappedClientException) {
      return _classifyRhttp(error.rhttpException);
    }
    if (error is rhttp.RhttpException) {
      return _classifyRhttp(error);
    }
    if (error is http.RequestAbortedException) {
      return NetworkFailure(NetworkFailureKind.cancelled, cause: error);
    }
    if (error is HandshakeException || error is TlsException) {
      // dart:io has no reliable certificate-specific subtype.  A textual
      // "certificate"/"handshake" guess was unsafe: injected TLS resets
      // commonly contain those words.  Only rhttp's structured
      // RhttpInvalidCertificateException is a certificate mismatch.
      return NetworkFailure(NetworkFailureKind.tlsHandshake, cause: error);
    }
    if (error is SocketException) {
      return NetworkFailure(_classifySocket(error), cause: error);
    }
    if (error is http.ClientException) {
      return NetworkFailure(_classifyMessage(error.toString()), cause: error);
    }
    return NetworkFailure(NetworkFailureKind.unknown, cause: error);
  }

  static bool isFallbackEligible(Object error) {
    if (error is NetworkRouteProbeException) return true;
    return const {
      NetworkFailureKind.dns,
      NetworkFailureKind.connect,
      NetworkFailureKind.timeout,
      NetworkFailureKind.reset,
      // The GFW injects RSTs during the TLS handshake, which Dart surfaces
      // as a HandshakeException without cert/hostname keywords (classified
      // `tlsHandshake`). Without this entry the DoH tier would never be
      // tried inside the wall. `certificateMismatch` stays terminal: it is
      // the signal that someone swapped the certificate on the path.
      NetworkFailureKind.tlsHandshake,
    }.contains(classify(error).kind);
  }

  static NetworkFailureKind _classifySocket(SocketException error) {
    final text = error.toString().toLowerCase();
    // Never infer certificate replacement from SocketException text.  A
    // handshake/reset is a transport failure and may be retried on a strict
    // route; certificate validation is represented structurally by rhttp.
    if (text.contains('handshake')) return NetworkFailureKind.tlsHandshake;
    if (text.contains('failed host lookup') ||
        text.contains('getaddrinfo') ||
        text.contains('name or service not known') ||
        text.contains('temporary failure in name resolution')) {
      return NetworkFailureKind.dns;
    }
    if (text.contains('reset') ||
        text.contains('broken pipe') ||
        text.contains('connection closed') ||
        text.contains('eof')) {
      return NetworkFailureKind.reset;
    }
    if (text.contains('timed out') || text.contains('timeout')) {
      return NetworkFailureKind.timeout;
    }
    return NetworkFailureKind.connect;
  }

  static NetworkFailureKind _classifyMessage(String message) {
    final text = message.toLowerCase();
    if (text.contains('handshake')) return NetworkFailureKind.tlsHandshake;
    if (text.contains('timeout') || text.contains('timed out')) {
      return NetworkFailureKind.timeout;
    }
    if (text.contains('reset') || text.contains('closed')) {
      return NetworkFailureKind.reset;
    }
    if (text.contains('lookup') || text.contains('dns')) {
      return NetworkFailureKind.dns;
    }
    return NetworkFailureKind.unknown;
  }

  static NetworkFailure _classifyRhttp(rhttp.RhttpException error) {
    return switch (error) {
      rhttp.RhttpInvalidCertificateException() => NetworkFailure(
        NetworkFailureKind.certificateMismatch,
        cause: error,
      ),
      rhttp.RhttpTimeoutException() => NetworkFailure(
        NetworkFailureKind.timeout,
        cause: error,
      ),
      rhttp.RhttpCancelException() => NetworkFailure(
        NetworkFailureKind.cancelled,
        cause: error,
      ),
      rhttp.RhttpRedirectException() => NetworkFailure(
        NetworkFailureKind.redirect,
        cause: error,
      ),
      rhttp.RhttpStatusCodeException(:final statusCode) => NetworkFailure(
        _classifyStatus(statusCode),
        cause: error,
      ),
      rhttp.RhttpConnectionException(:final message) => NetworkFailure(
        _classifyConnectionMessage(message),
        cause: error,
      ),
      rhttp.RhttpClientDisposedException() => NetworkFailure(
        NetworkFailureKind.unknown,
        cause: error,
      ),
      rhttp.RhttpInterceptorException(:final error) => classify(error),
      rhttp.RhttpUnknownException() => NetworkFailure(
        NetworkFailureKind.unknown,
        cause: error,
      ),
      _ => NetworkFailure(NetworkFailureKind.unknown, cause: error),
    };
  }

  static NetworkFailureKind _classifyStatus(int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      return NetworkFailureKind.auth;
    }
    if (statusCode == 429) return NetworkFailureKind.rateLimit;
    return NetworkFailureKind.http;
  }

  static NetworkFailureKind _classifyConnectionMessage(String message) {
    final text = message.toLowerCase();
    if (text.contains('timed out') || text.contains('timeout')) {
      return NetworkFailureKind.timeout;
    }
    if (text.contains('lookup') ||
        text.contains('dns') ||
        text.contains('name or service')) {
      return NetworkFailureKind.dns;
    }
    if (text.contains('reset') ||
        text.contains('closed') ||
        text.contains('broken pipe') ||
        text.contains('eof')) {
      return NetworkFailureKind.reset;
    }
    return NetworkFailureKind.connect;
  }
}

/// Safe, bounded diagnostics. Events carry only canonical host and route
/// metadata; URLs, query strings, cookies, tokens, bodies and full IPs never
/// enter this object.
class NetworkDiagnosticEvent {
  const NetworkDiagnosticEvent({
    required this.host,
    required this.purpose,
    required this.route,
    required this.ipFamily,
    required this.failure,
    required this.latency,
    required this.revision,
    this.dnsSource = DnsSource.none,
    this.capability = 'baseline',
  });

  final String host;
  final PixivDestinationPurpose purpose;
  final NetworkRouteKind route;
  final NetworkIpFamily ipFamily;
  final NetworkFailureKind failure;
  final Duration latency;
  final NetworkRevision revision;
  final DnsSource dnsSource;
  final String capability;

  Map<String, Object> toMap() => {
    'host': host,
    'purpose': purpose.name,
    'route': route.name,
    'ip_family': ipFamily.name,
    'dns_source': dnsSource.name,
    'failure': failure.name,
    'latency_ms': latency.inMilliseconds,
    'network_revision': revision.value,
    'network_identity': revision.networkIdentity,
    'capability': capability,
  };
}

class NetworkDiagnostics {
  NetworkDiagnostics({this.maxEvents = 64}) : assert(maxEvents > 0);

  final int maxEvents;
  final List<NetworkDiagnosticEvent> _events = [];

  List<NetworkDiagnosticEvent> get events => List.unmodifiable(_events);

  void record(NetworkDiagnosticEvent event) {
    _events.add(event);
    if (_events.length > maxEvents) {
      _events.removeRange(0, _events.length - maxEvents);
    }
  }

  void clear() => _events.clear();
}
