import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

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

  /// Returns the complete exact-host set for a purpose. Consumers such as a
  /// WebView route session retain this set with the captured network revision
  /// instead of reconstructing a broader suffix allowlist.
  Set<String> allowedHosts(PixivDestinationPurpose purpose) {
    return Set.unmodifiable(switch (purpose) {
      PixivDestinationPurpose.appApi => {'app-api.pixiv.net'},
      PixivDestinationPurpose.oauth => {'oauth.secure.pixiv.net'},
      PixivDestinationPurpose.accountsWeb => {
        'app-api.pixiv.net',
        'accounts.pixiv.net',
      },
      PixivDestinationPurpose.pixivWeb => {'www.pixiv.net'},
      PixivDestinationPurpose.image => {'i.pximg.net', 's.pximg.net'},
    });
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

enum NetworkRouteKind { direct, secureDns, ech, webViewLoopback }

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
  });

  factory NetworkRoute.direct(NetworkRevision revision) =>
      NetworkRoute._(kind: NetworkRouteKind.direct, revision: revision);

  factory NetworkRoute.secureDns(
    NetworkRevision revision,
    InternetAddress address, {
    DnsSource dnsSource = DnsSource.system,
    Duration? ttl,
  }) => NetworkRoute._(
    kind: NetworkRouteKind.secureDns,
    revision: revision,
    address: address,
    dnsSource: dnsSource,
    ttl: ttl,
  );

  final NetworkRouteKind kind;
  final NetworkRevision revision;
  final InternetAddress? address;
  final DnsSource dnsSource;
  final Duration? ttl;

  NetworkIpFamily get ipFamily => switch (address?.type) {
    InternetAddressType.IPv4 => NetworkIpFamily.ipv4,
    InternetAddressType.IPv6 => NetworkIpFamily.ipv6,
    _ => NetworkIpFamily.unknown,
  };

  String get key => [
    revision.value,
    revision.networkIdentity,
    kind.name,
    ipFamily.name,
    dnsSource.name,
    address?.address ?? '',
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
    if (error is NetworkRedirectException) {
      return NetworkFailure(NetworkFailureKind.redirect, cause: error);
    }
    if (error is HandshakeException || error is TlsException) {
      final text = error.toString().toLowerCase();
      final isCertificate =
          text.contains('cert') ||
          text.contains('hostname') ||
          text.contains('verify') ||
          text.contains('peer');
      return NetworkFailure(
        isCertificate
            ? NetworkFailureKind.certificateMismatch
            : NetworkFailureKind.tlsHandshake,
        cause: error,
      );
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
    return const {
      NetworkFailureKind.dns,
      NetworkFailureKind.connect,
      NetworkFailureKind.timeout,
      NetworkFailureKind.reset,
    }.contains(classify(error).kind);
  }

  static NetworkFailureKind _classifySocket(SocketException error) {
    final text = error.toString().toLowerCase();
    if (text.contains('certificate') || text.contains('handshake')) {
      return NetworkFailureKind.certificateMismatch;
    }
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
    if (text.contains('certificate') || text.contains('handshake')) {
      return NetworkFailureKind.certificateMismatch;
    }
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
