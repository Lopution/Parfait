import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../settings/network_endpoint_validation.dart';
import '../local_network_address.dart';
import 'dns_message.dart';
import 'network_contracts.dart';
import 'secure_resolver_support.dart';

export 'secure_resolver_support.dart' show isPublicNetworkAddress;

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
    required List<int> echConfig,
    required this.ttl,
    List<InternetAddress> frontAddresses = const [],
  }) : echConfig = Uint8List.fromList(echConfig),
       frontAddresses = List<InternetAddress>.unmodifiable(frontAddresses);

  /// A private copy is kept so a caller cannot mutate the resolver's cached
  /// config bytes after a successful lookup.
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
    validateDnsName(host);
    if (cancelSignal?.isCancelled ?? false) {
      throw const NetworkFailureException(NetworkFailureKind.cancelled);
    }
    final lookup = InternetAddress.lookup(
      host,
      type: InternetAddressType.any,
    ).timeout(lookupTimeout);
    final addresses = await raceResolverCancellation(lookup, cancelSignal);
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
    List<String>? echEndpointUrls,
    this.blockedHosts = const {},
    this.maxResponseBytes = 64 * 1024,
    this.maxTtl = const Duration(minutes: 10),
    this.minTtl = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 8),
    this.maxAddresses = 8,
    this.endpointFailureWindow = const Duration(seconds: 30),
    this.clock = DateTime.now,
  }) : assert(endpointUrls.isNotEmpty, 'at least one DoH endpoint required'),
       _client = client ?? staticMappedDohClient(hostOverrides),
       _ownsClient = client == null,
       _endpoints = List.of(endpointUrls),
       _echEndpoints = List.of(echEndpointUrls ?? endpointUrls);

  /// DNS-bootstrap-free endpoint resolution: maps an endpoint's hostname to
  /// fixed public IPs (e.g. Cloudflare DoH `1dot1dot1dot1.cloudflare-dns.com`
  /// → `104.16.248.249`). Cloudflare Anycast serves every domain on any of
  /// its IPs, so the DoH request's real SNI is still `cloudflare-dns.com`
  /// while the TCP peer is the static IP — no polluted system-DNS round trip
  /// and no resolver recursion.
  final Map<String, List<InternetAddress>> hostOverrides;

  /// Endpoint hosts on the local network the app may not reach: a query
  /// to one fails at once and the next endpoint is tried.
  final Set<String> blockedHosts;

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

  /// ECH HTTPS-RR endpoints. The ECH config is queried through Alibaba
  /// DNS (`lookup_alidns_https_ech`), which is reachable inside the wall
  /// while the Cloudflare anycast endpoints are not; `cloudflare-ech.com`
  /// answers are not poisoned there (only *.pixiv.net A records are).
  final List<String> _echEndpoints;
  int _echEndpointCursor = 0;
  final Map<String, DateTime> _endpointFailedAt = {};
  final Map<_AddressCacheKey, _AddressCacheEntry> _addressCache = {};
  final Map<_AddressCacheKey, Future<ResolvedHost>> _addressInflight = {};
  final Map<_EchCacheKey, _EchCacheEntry> _echCache = {};
  final Map<_EchCacheKey, Future<EchConfigResult>> _echInflight = {};
  static const int _maxAddressCacheEntries = 32;
  static const int _maxEchCacheEntries = 16;
  int _endpointCursor = 0;
  bool _disposed = false;
  int _nextQueryId = 0;
  String? _reboundInitialIdentity;

  NetworkRevision _effectiveRevision(NetworkRevision revision) =>
      _reboundInitialIdentity != null &&
          revision.value == 0 &&
          revision.networkIdentity == 'initial'
      ? NetworkRevision(0, networkIdentity: _reboundInitialIdentity!)
      : revision;

  /// Returns a fresh cached ECH config for [frontHost] at [revision], or null.
  EchConfigResult? cachedEchConfig(String frontHost, NetworkRevision revision) {
    if (_disposed) return null;
    final key = _EchCacheKey(frontHost, revision);
    final cached = _echCache[key];
    if (cached == null) return null;
    if (!cached.isUsable(clock())) {
      _echCache.remove(key);
      return null;
    }
    return _copyEchResult(cached.result);
  }

  /// Pre-populates the ECH cache (e.g. from the main isolate into the image worker).
  void seedEchConfig(
    String frontHost,
    NetworkRevision revision,
    EchConfigResult result,
  ) {
    if (_disposed || result.echConfig.isEmpty) return;
    _rememberEchResult(
      _EchCacheKey(frontHost, revision),
      _copyEchResult(result),
    );
  }

  /// Re-keys cached and in-flight `0/initial` DNS & ECH entries in place when
  /// the first real network identity arrives at cold start.
  void rebindInitialIdentity(String identity) {
    if (_disposed || identity == 'initial') return;
    _reboundInitialIdentity = identity;
    final rebound = NetworkRevision(0, networkIdentity: identity);
    for (final entry in _addressCache.entries.toList(growable: false)) {
      if (entry.key.revision.value == 0 &&
          entry.key.revision.networkIdentity == 'initial') {
        _addressCache.remove(entry.key);
        final r = entry.value.result;
        _addressCache[_AddressCacheKey(
          entry.key.host,
          rebound,
        )] = _AddressCacheEntry(
          ResolvedHost(
            host: r.host,
            addresses: r.addresses,
            dnsSource: r.dnsSource,
            revision: rebound,
            ttl: r.ttl,
          ),
          entry.value.createdAt,
        );
      }
    }
    for (final entry in _addressInflight.entries.toList(growable: false)) {
      if (entry.key.revision.value == 0 &&
          entry.key.revision.networkIdentity == 'initial') {
        unawaited(_addressInflight.remove(entry.key));
        _addressInflight[_AddressCacheKey(entry.key.host, rebound)] =
            entry.value;
      }
    }
    for (final entry in _echCache.entries.toList(growable: false)) {
      if (entry.key.revision.value == 0 &&
          entry.key.revision.networkIdentity == 'initial') {
        _echCache.remove(entry.key);
        _echCache[_EchCacheKey(entry.key.frontHost, rebound)] = entry.value;
      }
    }
    for (final entry in _echInflight.entries.toList(growable: false)) {
      if (entry.key.revision.value == 0 &&
          entry.key.revision.networkIdentity == 'initial') {
        unawaited(_echInflight.remove(entry.key));
        _echInflight[_EchCacheKey(entry.key.frontHost, rebound)] = entry.value;
      }
    }
  }

  @override
  Future<ResolvedHost> resolve(
    String host, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async {
    validateDnsName(host);
    _checkUsable();
    if (cancelSignal?.isCancelled ?? false) {
      throw const NetworkFailureException(NetworkFailureKind.cancelled);
    }

    final key = _AddressCacheKey(host, revision);
    final cached = _addressCache[key];
    if (cached != null) {
      if (cached.isUsable(clock())) return _copyResolved(cached.result);
      _addressCache.remove(key);
    }

    // Every caller of the same host and revision shares one DNS flight. A
    // caller's cancel ends only its own wait; the flight completes and is
    // cached for the others (a cold feed sends eight image requests at once,
    // each with its own cancel signal).
    return _copyResolved(
      await raceResolverCancellation(_sharedAddress(key), cancelSignal),
    );
  }

  Future<ResolvedHost> _sharedAddress(_AddressCacheKey key) {
    final pending = _addressInflight[key];
    if (pending != null) return pending;
    late final Future<ResolvedHost> flight;
    flight = () async {
      try {
        final result = await _resolveUncached(key.host, key.revision);
        final effRev = _effectiveRevision(key.revision);
        final effectiveKey = _AddressCacheKey(key.host, effRev);
        final effectiveResult = effRev == key.revision
            ? result
            : ResolvedHost(
                host: result.host,
                addresses: result.addresses,
                dnsSource: result.dnsSource,
                revision: effRev,
                ttl: result.ttl,
              );
        _rememberAddress(effectiveKey, effectiveResult);
        return effectiveResult;
      } finally {
        final effKey = _AddressCacheKey(
          key.host,
          _effectiveRevision(key.revision),
        );
        if (identical(_addressInflight[key], flight)) {
          unawaited(_addressInflight.remove(key));
        }
        if (identical(_addressInflight[effKey], flight)) {
          unawaited(_addressInflight.remove(effKey));
        }
      }
    }();
    _addressInflight[key] = flight;
    return flight;
  }

  Future<ResolvedHost> _resolveUncached(
    String host,
    NetworkRevision revision,
  ) async {
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
        final result = await _query(endpoint, host, revision);
        _markEndpointHealthy(endpoint);
        return result;
      } on Object catch (error) {
        lastError = error;
        _markEndpointFailed(endpoint);
      }
    }
    _endpointCursor = (_endpointCursor + 1) % _endpoints.length;
    throw lastError ??
        const SecureResolutionException('all DoH endpoints failed');
  }

  static ResolvedHost _copyResolved(ResolvedHost result) => ResolvedHost(
    host: result.host,
    addresses: result.addresses,
    dnsSource: result.dnsSource,
    revision: result.revision,
    ttl: result.ttl,
  );

  void _rememberAddress(_AddressCacheKey key, ResolvedHost result) {
    if (_disposed) return;
    _addressCache[key] = _AddressCacheEntry(result, clock());
    final now = clock();
    _addressCache.removeWhere((_, entry) => !entry.isUsable(now));
    if (_addressCache.length <= _maxAddressCacheEntries) return;
    final oldest = _addressCache.entries.toList()
      ..sort((a, b) => a.value.createdAt.compareTo(b.value.createdAt));
    for (final entry in oldest.take(
      _addressCache.length - _maxAddressCacheEntries,
    )) {
      _addressCache.remove(entry.key);
    }
  }

  Uri _validateEndpointUri(String endpoint) {
    final uri = validateDohEndpointUri(endpoint);
    if (uri == null) {
      throw const SecureResolutionException('invalid DoH endpoint');
    }
    final endpointHost = uri.host.toLowerCase();
    if (blockedHosts.contains(uri.host) ||
        blockedHosts.contains(endpointHost)) {
      throw LocalNetworkBlocked(uri.host);
    }
    return uri;
  }

  Future<ResolvedHost> _query(
    String endpoint,
    String host,
    NetworkRevision revision,
  ) async {
    final endpointUri = _validateEndpointUri(endpoint);
    final id = _nextQueryId++ & 0xffff;
    final payload = encodeQuery(id: id, name: host, type: 1);

    final request = http.Request('POST', endpointUri)
      ..headers['content-type'] = 'application/dns-message'
      ..headers['accept'] = 'application/dns-message'
      ..bodyBytes = payload;

    final response = await _client.send(request).timeout(requestTimeout);
    if (response.statusCode != 200) {
      await response.stream.drain<void>().timeout(requestTimeout);
      throw SecureResolutionException(
        'DoH endpoint $endpoint HTTP '
        '${response.statusCode}',
      );
    }
    final body = await response.stream
        .fold<List<int>>(<int>[], (acc, chunk) {
          if (acc.length + chunk.length > maxResponseBytes) {
            throw const SecureResolutionException('DoH response too large');
          }
          acc.addAll(chunk);
          return acc;
        })
        .timeout(requestTimeout);
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
    validateDnsName(frontHost);
    _checkUsable();
    if (cancelSignal?.isCancelled ?? false) {
      throw const NetworkFailureException(NetworkFailureKind.cancelled);
    }

    final key = _EchCacheKey(frontHost, revision);
    final cached = _echCache[key];
    if (cached != null) {
      if (cached.isUsable(clock())) {
        return _copyEchResult(cached.result);
      }
      _echCache.remove(key);
    }

    // Shared like [resolve]: a caller's cancel ends only its own wait.
    return _copyEchResult(
      await raceResolverCancellation(_sharedEch(key), cancelSignal),
    );
  }

  Future<EchConfigResult> _sharedEch(_EchCacheKey key) {
    final pending = _echInflight[key];
    if (pending != null) return pending;
    late final Future<EchConfigResult> flight;
    flight = () async {
      try {
        final result = await _lookupEchConfigUncached(
          key.frontHost,
          key.revision,
        );
        final effKey = _EchCacheKey(
          key.frontHost,
          _effectiveRevision(key.revision),
        );
        _rememberEchResult(effKey, result);
        return result;
      } finally {
        final effKey = _EchCacheKey(
          key.frontHost,
          _effectiveRevision(key.revision),
        );
        if (identical(_echInflight[key], flight)) {
          unawaited(_echInflight.remove(key));
        }
        if (identical(_echInflight[effKey], flight)) {
          unawaited(_echInflight.remove(effKey));
        }
      }
    }();
    _echInflight[key] = flight;
    return flight;
  }

  Future<EchConfigResult> _lookupEchConfigUncached(
    String frontHost,
    NetworkRevision revision,
  ) async {
    _checkUsable();

    final candidates = <String>[];
    for (var i = 0; i < _echEndpoints.length; i++) {
      final endpoint =
          _echEndpoints[(_echEndpointCursor + i) % _echEndpoints.length];
      if (_isEndpointHealthy(endpoint)) candidates.add(endpoint);
    }
    if (candidates.isEmpty) {
      candidates.add(_echEndpoints[_echEndpointCursor % _echEndpoints.length]);
    }

    Object? lastError;
    for (final endpoint in candidates) {
      try {
        final result = await _queryEch(endpoint, frontHost, revision);
        _markEndpointHealthy(endpoint);
        return result;
      } on Object catch (error) {
        lastError = error;
        _markEndpointFailed(endpoint);
      }
    }
    _echEndpointCursor = (_echEndpointCursor + 1) % _echEndpoints.length;
    throw lastError ??
        const SecureResolutionException('all DoH endpoints failed');
  }

  static EchConfigResult _copyEchResult(EchConfigResult result) =>
      EchConfigResult(
        echConfig: result.echConfig,
        ttl: result.ttl,
        frontAddresses: result.frontAddresses,
      );

  void _rememberEchResult(_EchCacheKey key, EchConfigResult result) {
    if (_disposed) return;
    _echCache[key] = _EchCacheEntry(result, clock());
    _trimEchCache();
  }

  void _trimEchCache() {
    final now = clock();
    _echCache.removeWhere((_, entry) => !entry.isUsable(now));
    if (_echCache.length <= _maxEchCacheEntries) return;
    final oldest = _echCache.entries.toList()
      ..sort((a, b) => a.value.createdAt.compareTo(b.value.createdAt));
    for (final entry in oldest.take(_echCache.length - _maxEchCacheEntries)) {
      _echCache.remove(entry.key);
    }
  }

  Future<EchConfigResult> _queryEch(
    String endpoint,
    String frontHost,
    NetworkRevision revision,
  ) async {
    final endpointUri = _validateEndpointUri(endpoint);
    final id = _nextQueryId++ & 0xffff;
    final payload = encodeQuery(id: id, name: frontHost, type: 65);

    final request = http.Request('POST', endpointUri)
      ..headers['content-type'] = 'application/dns-message'
      ..headers['accept'] = 'application/dns-message'
      ..bodyBytes = payload;

    final response = await _client.send(request).timeout(requestTimeout);
    if (response.statusCode != 200) {
      await response.stream.drain<void>().timeout(requestTimeout);
      throw SecureResolutionException(
        'DoH endpoint $endpoint HTTP '
        '${response.statusCode}',
      );
    }
    final body = await response.stream
        .fold<List<int>>(<int>[], (acc, chunk) {
          if (acc.length + chunk.length > maxResponseBytes) {
            throw const SecureResolutionException('DoH response too large');
          }
          acc.addAll(chunk);
          return acc;
        })
        .timeout(requestTimeout);
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
    _addressCache.clear();
    _addressInflight.clear();
    _echCache.clear();
    _echInflight.clear();
    if (_ownsClient) {
      _client.close();
    }
  }
}

class _AddressCacheKey {
  const _AddressCacheKey(this.host, this.revision);

  final String host;
  final NetworkRevision revision;

  @override
  bool operator ==(Object other) =>
      other is _AddressCacheKey &&
      other.host == host &&
      other.revision.value == revision.value &&
      other.revision.networkIdentity == revision.networkIdentity;

  @override
  int get hashCode =>
      Object.hash(host, revision.value, revision.networkIdentity);
}

class _AddressCacheEntry {
  _AddressCacheEntry(this.result, this.createdAt);

  final ResolvedHost result;
  final DateTime createdAt;

  bool isUsable(DateTime now) =>
      !now.isBefore(createdAt) && now.difference(createdAt) < result.ttl;
}

class _EchCacheKey {
  const _EchCacheKey(this.frontHost, this.revision);

  final String frontHost;
  final NetworkRevision revision;

  @override
  bool operator ==(Object other) =>
      other is _EchCacheKey &&
      other.frontHost == frontHost &&
      other.revision.value == revision.value &&
      other.revision.networkIdentity == revision.networkIdentity;

  @override
  int get hashCode =>
      Object.hash(frontHost, revision.value, revision.networkIdentity);
}

class _EchCacheEntry {
  _EchCacheEntry(this.result, this.createdAt);

  final EchConfigResult result;
  final DateTime createdAt;

  bool isUsable(DateTime now) =>
      !now.isBefore(createdAt) && now.difference(createdAt) < result.ttl;
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
    validateDnsName(host);
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
