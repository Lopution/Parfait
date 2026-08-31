import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'dns_message.dart';
import 'network_contracts.dart';

abstract interface class SecureResolver {
  Future<ResolvedHost> resolve(
    String host, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  });

  Future<void> dispose();
}

/// Optional capability exposed by resolvers that can query HTTPS records.
/// Keeping it separate from [SecureResolver] means test/static resolvers and
/// future DNS implementations do not need to fake ECH support just to serve
/// address answers.
abstract interface class EchConfigResolver {
  Future<EchConfigResult> lookupEchConfig(
    String frontHost, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  });
}

/// Result of an ECH config lookup: the raw ECH config list bytes plus the
/// record TTL (already clamped) and the front host's connect addresses
/// (from the HTTPS RR's ipv4hint — the only clean source for the ECH
/// connection target; system DNS / mainland DoH answers for the target
/// host are polluted).
class EchConfigResult {
  EchConfigResult({
    required this.echConfig,
    required this.ttl,
    this.frontAddresses = const [],
  });

  final Uint8List echConfig;
  final Duration ttl;

  /// Connect target IPs for the ECH front (outer SNI host). Empty when the
  /// HTTPS RR carries no ipv4hint; the policy then falls back to resolving
  /// the front host itself.
  final List<InternetAddress> frontAddresses;
}

class ResolvedHost {
  ResolvedHost({
    required this.host,
    required List<InternetAddress> addresses,
    required this.dnsSource,
    required this.revision,
    this.ttl = const Duration(seconds: 30),
  }) : addresses = List.unmodifiable(addresses);

  final String host;
  final List<InternetAddress> addresses;
  final DnsSource dnsSource;
  final NetworkRevision revision;
  final Duration ttl;
}

class SecureResolutionException implements Exception {
  const SecureResolutionException(this.message);

  final String message;

  @override
  String toString() => 'SecureResolutionException: $message';
}

/// Resolver backed by the platform's configured DNS resolver. It is the
/// default because it preserves the user's ordinary direct network path; the
/// resolved addresses are only used for a strict connection attempt whose
/// request URI still owns TLS SNI and HTTP Host.
class SystemSecureResolver implements SecureResolver {
  const SystemSecureResolver({this.lookupTimeout = const Duration(seconds: 8)});

  final Duration lookupTimeout;

  @override
  Future<ResolvedHost> resolve(
    String host, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async {
    _validateDnsName(host);
    if (cancelSignal?.isCancelled ?? false) {
      throw const NetworkFailureException(NetworkFailureKind.cancelled);
    }
    final lookup = InternetAddress.lookup(
      host,
      type: InternetAddressType.any,
    ).timeout(lookupTimeout);
    final addresses = await _raceCancellation(lookup, cancelSignal);
    final safe = addresses
        .where(isPublicNetworkAddress)
        .toList(growable: false);
    if (safe.isEmpty) {
      throw const SecureResolutionException('no public DNS address');
    }
    return ResolvedHost(
      host: host,
      addresses: safe,
      dnsSource: DnsSource.system,
      revision: revision,
    );
  }

  @override
  Future<void> dispose() async {}
}

/// DoH (RFC 8484) resolver speaking `application/dns-message` over HTTPS.
///
/// Bootstrap properties (pinned by the design and the registry):
///
/// - Endpoint URLs use IP-literal hosts (e.g. `https://1.1.1.1/dns-query`),
///   so no system DNS round trip is needed before the first query, and the
///   endpoint certificate carries an `iPAddress` SAN — hostname verification
///   succeeds normally; no certificate compromise is involved.
/// - `resolve()` only accepts a canonical name from the caller; in this
///   codebase the only caller is [NetworkAccessPolicy.resolve], which
///   receives a [PixivDestination] already constrained by
///   [PixivDestinationRegistry], so the resolver cannot become a generic
///   open resolver through the production wiring.
/// - Endpoints are tried in order; a failing endpoint moves the next call
///   to the next endpoint (bounded circuit breaker).
/// - Responses are bounded (size cap), time-bounded, cancellable, and TTLs
///   are clamped to [maxTtl]. Only public addresses are returned.
class DohResolver implements SecureResolver, EchConfigResolver {
  DohResolver({
    required List<String> endpointUrls,
    http.Client? client,
    this.hostOverrides = const {},
    this.maxResponseBytes = 64 * 1024,
    this.maxTtl = const Duration(minutes: 10),
    this.minTtl = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 8),
    this.maxAddresses = 8,
    this.endpointFailureWindow = const Duration(seconds: 30),
    this.clock = DateTime.now,
  }) : assert(endpointUrls.isNotEmpty, 'at least one DoH endpoint required'),
       _client = client ?? _staticMappedClient(hostOverrides),
       _ownsClient = client == null,
       _endpoints = List.of(endpointUrls);

  /// DNS-bootstrap-free endpoint resolution: maps an endpoint's hostname to
  /// fixed public IPs (e.g. Cloudflare DoH `1dot1dot1dot1.cloudflare-dns.com`
  /// → `104.16.248.249`). Cloudflare Anycast serves every domain on any of
  /// its IPs, so the DoH request's real SNI is still `cloudflare-dns.com`
  /// while the TCP peer is the static IP — no polluted system-DNS round trip
  /// and no resolver recursion (PixEz `DnsSettings.static` equivalent).
  final Map<String, List<InternetAddress>> hostOverrides;

  /// Maximum accepted response body size (hard cap against amplification).
  final int maxResponseBytes;

  /// TTL clamp: DNS answers above this are reported as this value.
  final Duration maxTtl;

  /// TTL floor: answers below this are reported as this value.
  final Duration minTtl;

  final Duration requestTimeout;
  final int maxAddresses;

  /// A failing endpoint is skipped for this long before being retried.
  final Duration endpointFailureWindow;

  final DateTime Function() clock;

  final http.Client _client;
  final bool _ownsClient;
  final List<String> _endpoints;
  final Map<String, DateTime> _endpointFailedAt = {};
  int _endpointCursor = 0;
  bool _disposed = false;

  int _nextQueryId = 0;

  @override
  Future<ResolvedHost> resolve(
    String host, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async {
    _validateDnsName(host);
    _checkUsable();
    if (cancelSignal?.isCancelled ?? false) {
      throw const NetworkFailureException(NetworkFailureKind.cancelled);
    }

    // Find a healthy endpoint starting at the cursor (round-robin start).
    final candidates = <String>[];
    for (var i = 0; i < _endpoints.length; i++) {
      final endpoint = _endpoints[(_endpointCursor + i) % _endpoints.length];
      if (_isEndpointHealthy(endpoint)) candidates.add(endpoint);
    }
    if (candidates.isEmpty) {
      // All endpoints are in their failure window: try the primary anyway
      // so the resolver degrades to "last resort probe" instead of a hard
      // block when the network genuinely changed.
      candidates.add(_endpoints[_endpointCursor % _endpoints.length]);
    }

    Object? lastError;
    for (final endpoint in candidates) {
      try {
        final result = await _query(endpoint, host, revision, cancelSignal);
        _markEndpointHealthy(endpoint);
        return result;
      } on Object catch (error) {
        lastError = error;
        _markEndpointFailed(endpoint);
        if (error is NetworkFailureException &&
            error.kind == NetworkFailureKind.cancelled) {
          rethrow;
        }
      }
    }
    _endpointCursor = (_endpointCursor + 1) % _endpoints.length;
    throw lastError ??
        const SecureResolutionException('all DoH endpoints failed');
  }

  Future<ResolvedHost> _query(
    String endpoint,
    String host,
    NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  ) async {
    if (cancelSignal?.isCancelled ?? false) {
      throw const NetworkFailureException(NetworkFailureKind.cancelled);
    }
    final id = _nextQueryId++ & 0xffff;
    final payload = encodeQuery(id: id, name: host, type: 1);

    final request =
        http.AbortableRequest(
            'POST',
            Uri.parse(endpoint),
            abortTrigger: cancelSignal?.whenCancel,
          )
          ..headers['content-type'] = 'application/dns-message'
          ..headers['accept'] = 'application/dns-message'
          ..bodyBytes = payload;

    final future = _client.send(request).timeout(requestTimeout);
    final response = await _raceCancellation(future, cancelSignal);
    if (response.statusCode != 200) {
      await _raceCancellation(
        response.stream.drain<void>().timeout(requestTimeout),
        cancelSignal,
      );
      throw SecureResolutionException(
        'DoH endpoint $endpoint HTTP '
        '${response.statusCode}',
      );
    }
    final body = await _raceCancellation(
      response.stream
          .fold<List<int>>(<int>[], (acc, chunk) {
            if (acc.length + chunk.length > maxResponseBytes) {
              throw const SecureResolutionException('DoH response too large');
            }
            acc.addAll(chunk);
            return acc;
          })
          .timeout(requestTimeout),
      cancelSignal,
    );
    if (body.length > maxResponseBytes) {
      throw const SecureResolutionException('DoH response too large');
    }

    final message = decodeResponse(Uint8List.fromList(body));
    if (message.id != id) {
      throw const SecureResolutionException('DoH response id mismatch');
    }
    if (message.isTruncated) {
      throw const SecureResolutionException('DoH response truncated');
    }
    if (!message.isOk) {
      throw SecureResolutionException('DoH rcode ${message.rcode}');
    }
    final addresses = <InternetAddress>[];
    for (final answer in message.addressAnswers) {
      final address = answer.address!;
      if (!isPublicNetworkAddress(address)) continue;
      addresses.add(address);
      if (addresses.length >= maxAddresses) break;
    }
    if (addresses.isEmpty) {
      throw const SecureResolutionException('DoH returned no public address');
    }

    var ttl = const Duration(seconds: 30);
    if (message.addressAnswers.isNotEmpty) {
      final rawTtl = message.addressAnswers
          .map((answer) => answer.ttl)
          .reduce((a, b) => a < b ? a : b);
      ttl = Duration(seconds: rawTtl);
    }
    if (ttl < minTtl) ttl = minTtl;
    if (ttl > maxTtl) ttl = maxTtl;

    return ResolvedHost(
      host: host,
      addresses: addresses,
      dnsSource: DnsSource.doh,
      revision: revision,
      ttl: ttl,
    );
  }

  /// Queries the HTTPS RR (type 65) for [frontHost] and extracts the
  /// `ech` SvcParam (key 5). Reuses the same endpoint rotation, failure
  /// window, cancellation, size cap and TTL clamping as [resolve].
  ///
  /// Throws [SecureResolutionException] when the query fails, the record
  /// has no `ech` parameter, or the config cannot be parsed. Callers decide
  /// whether an ECH tier is available — this method never silently falls
  /// back to plain TLS.
  @override
  Future<EchConfigResult> lookupEchConfig(
    String frontHost, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async {
    _validateDnsName(frontHost);
    _checkUsable();
    if (cancelSignal?.isCancelled ?? false) {
      throw const NetworkFailureException(NetworkFailureKind.cancelled);
    }

    final candidates = <String>[];
    for (var i = 0; i < _endpoints.length; i++) {
      final endpoint = _endpoints[(_endpointCursor + i) % _endpoints.length];
      if (_isEndpointHealthy(endpoint)) candidates.add(endpoint);
    }
    if (candidates.isEmpty) {
      candidates.add(_endpoints[_endpointCursor % _endpoints.length]);
    }

    Object? lastError;
    for (final endpoint in candidates) {
      try {
        final result = await _queryEch(
          endpoint,
          frontHost,
          revision,
          cancelSignal,
        );
        _markEndpointHealthy(endpoint);
        return result;
      } on Object catch (error) {
        lastError = error;
        _markEndpointFailed(endpoint);
        if (error is NetworkFailureException &&
            error.kind == NetworkFailureKind.cancelled) {
          rethrow;
        }
      }
    }
    _endpointCursor = (_endpointCursor + 1) % _endpoints.length;
    throw lastError ??
        const SecureResolutionException('all DoH endpoints failed');
  }

  Future<EchConfigResult> _queryEch(
    String endpoint,
    String frontHost,
    NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  ) async {
    if (cancelSignal?.isCancelled ?? false) {
      throw const NetworkFailureException(NetworkFailureKind.cancelled);
    }
    final id = _nextQueryId++ & 0xffff;
    final payload = encodeQuery(id: id, name: frontHost, type: 65);

    final request =
        http.AbortableRequest(
            'POST',
            Uri.parse(endpoint),
            abortTrigger: cancelSignal?.whenCancel,
          )
          ..headers['content-type'] = 'application/dns-message'
          ..headers['accept'] = 'application/dns-message'
          ..bodyBytes = payload;

    final future = _client.send(request).timeout(requestTimeout);
    final response = await _raceCancellation(future, cancelSignal);
    if (response.statusCode != 200) {
      await _raceCancellation(
        response.stream.drain<void>().timeout(requestTimeout),
        cancelSignal,
      );
      throw SecureResolutionException(
        'DoH endpoint $endpoint HTTP '
        '${response.statusCode}',
      );
    }
    final body = await _raceCancellation(
      response.stream
          .fold<List<int>>(<int>[], (acc, chunk) {
            if (acc.length + chunk.length > maxResponseBytes) {
              throw const SecureResolutionException('DoH response too large');
            }
            acc.addAll(chunk);
            return acc;
          })
          .timeout(requestTimeout),
      cancelSignal,
    );
    if (body.length > maxResponseBytes) {
      throw const SecureResolutionException('DoH response too large');
    }

    final message = decodeResponse(Uint8List.fromList(body));
    if (message.id != id) {
      throw const SecureResolutionException('DoH response id mismatch');
    }
    if (message.isTruncated) {
      throw const SecureResolutionException('DoH response truncated');
    }
    if (!message.isOk) {
      throw SecureResolutionException('DoH rcode ${message.rcode}');
    }

    Uint8List? echConfig;
    int? ttlSeconds;
    List<InternetAddress> frontAddresses = const [];
    for (final answer in message.answers) {
      if (answer.type != 65 || answer.rdata == null) continue;
      final config = echConfigFromHttpsRdata(answer.rdata!);
      if (config != null) {
        echConfig = config;
        ttlSeconds = answer.ttl;
        // ipv4hint from the same RR: Cloudflare publishes the anycast IPs
        // the ECH front is served on (bypasses polluted answers for the
        // target host).
        final hints = ipv4HintFromHttpsRdata(answer.rdata!);
        if (hints.isNotEmpty) frontAddresses = hints;
        break;
      }
    }
    if (echConfig == null || echConfig.isEmpty) {
      throw const SecureResolutionException(
        'DoH response has no usable ech SvcParam',
      );
    }

    var ttl = Duration(seconds: ttlSeconds ?? 30);
    if (ttl < minTtl) ttl = minTtl;
    if (ttl > maxTtl) ttl = maxTtl;

    return EchConfigResult(
      echConfig: echConfig,
      ttl: ttl,
      frontAddresses: frontAddresses,
    );
  }

  bool _isEndpointHealthy(String endpoint) {
    final failedAt = _endpointFailedAt[endpoint];
    if (failedAt == null) return true;
    return clock().difference(failedAt) >= endpointFailureWindow;
  }

  void _markEndpointFailed(String endpoint) {
    _endpointFailedAt[endpoint] = clock();
  }

  void _markEndpointHealthy(String endpoint) {
    _endpointFailedAt.remove(endpoint);
  }

  void _checkUsable() {
    if (_disposed) throw StateError('DoH resolver is disposed');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_ownsClient) {
      _client.close();
    }
  }
}

/// A deterministic resolver useful for local integration and unit tests.
class StaticSecureResolver implements SecureResolver {
  StaticSecureResolver({
    required this.addresses,
    this.dnsSource = DnsSource.system,
  });

  final List<InternetAddress> addresses;
  final DnsSource dnsSource;

  @override
  Future<ResolvedHost> resolve(
    String host, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async {
    _validateDnsName(host);
    if (cancelSignal?.isCancelled ?? false) {
      throw const NetworkFailureException(NetworkFailureKind.cancelled);
    }
    final safe = addresses
        .where(isPublicNetworkAddress)
        .toList(growable: false);
    if (safe.isEmpty) {
      throw const SecureResolutionException('no public static address');
    }
    return ResolvedHost(
      host: host,
      addresses: safe,
      dnsSource: dnsSource,
      revision: revision,
    );
  }

  @override
  Future<void> dispose() async {}
}

Future<T> _raceCancellation<T>(
  Future<T> operation,
  NetworkCancelSignal? cancelSignal,
) {
  if (cancelSignal == null) return operation;
  return Future.any<T>([
    operation,
    cancelSignal.whenCancel.then<T>(
      (_) => throw const NetworkFailureException(NetworkFailureKind.cancelled),
    ),
  ]);
}

void _validateDnsName(String host) {
  if (host.isEmpty ||
      host.endsWith('.') ||
      host != host.toLowerCase() ||
      host.codeUnits.any((value) => value > 0x7f) ||
      InternetAddress.tryParse(host) != null) {
    throw const SecureResolutionException('unsafe DNS name');
  }
}

/// A dart:io client whose connectionFactory steers known endpoint hosts to
/// static IPs while keeping the URI's real hostname (SNI, Host header,
/// certificate chain and hostname verification all unchanged). Pinned by
/// test/tls_sni_behaviour_test.dart: a raw connectionFactory socket skips
/// TLS entirely, so every steered socket MUST be wrapped in
/// `SecureSocket.secure(socket, host: url.host)`.
http.Client _staticMappedClient(Map<String, List<InternetAddress>> overrides) {
  final client = HttpClient();
  client.findProxy = (_) => 'DIRECT';
  if (overrides.isNotEmpty) {
    client.connectionFactory = (url, proxyHost, proxyPort) {
      final addresses = overrides[url.host];
      if (addresses == null || addresses.isEmpty) {
        // Not an overridden host: normal destination, still needs the
        // SecureSocket wrapper (a bare connectionFactory socket skips TLS).
        if (proxyHost != null || proxyPort != null) {
          throw const SocketException('proxy route rejected');
        }
        return Socket.startConnect(url.host, url.port).then(
          (rawTask) => ConnectionTask.fromSocket<Socket>(
            rawTask.socket.then<Socket>(
              (socket) => SecureSocket.secure(socket, host: url.host),
            ),
            rawTask.cancel,
          ),
        );
      }
      if (proxyHost != null || proxyPort != null) {
        throw const SocketException('proxy route rejected');
      }
      return Socket.startConnect(addresses.first, url.port).then(
        (rawTask) => ConnectionTask.fromSocket<Socket>(
          rawTask.socket.then<Socket>(
            (socket) => SecureSocket.secure(socket, host: url.host),
          ),
          rawTask.cancel,
        ),
      );
    };
  }
  return IOClient(client);
}

bool isPublicNetworkAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return false;
  }
  if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
    final a = bytes[0];
    final b = bytes[1];
    final c = bytes[2];
    if (a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && (b == 0 || b == 2 || b == 168)) ||
        (a == 198 && (b == 18 || b == 19 || b == 51)) ||
        (a == 203 && b == 0 && c == 113) ||
        a >= 224) {
      return false;
    }
    return true;
  }
  if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
    final first = bytes[0];
    final second = bytes[1];
    // Unspecified (::), ULA (fc00::/7), documentation (2001:db8::/32),
    // and IPv4-mapped addresses are not accepted as public route candidates.
    if (bytes.every((value) => value == 0) ||
        (first & 0xfe) == 0xfc ||
        (first == 0x20 &&
            second == 0x01 &&
            bytes[2] == 0x0d &&
            bytes[3] == 0xb8) ||
        bytes.sublist(0, 10).every((value) => value == 0) &&
            bytes[10] == 0xff &&
            bytes[11] == 0xff) {
      return false;
    }
    return true;
  }
  return false;
}
