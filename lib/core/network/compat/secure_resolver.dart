import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'network_contracts.dart';
import 'strict_http_client.dart';

abstract interface class SecureResolver {
  Future<ResolvedHost> resolve(
    String host, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  });

  Future<void> dispose();
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

/// Optional approved encrypted-DNS resolver. It is not selected by default;
/// callers must explicitly opt in after their capability gate and must keep
/// the resolver endpoint exact. The endpoint is fixed to Cloudflare's DNS
/// JSON service and never accepts a user-provided hostname.
class DohResolver implements SecureResolver {
  DohResolver({http.Client? client, Uri? endpoint})
    : _client =
          client ??
          IOClient(
            NativeStrictConnector.create(
              NetworkRoute.direct(const NetworkRevision(0)),
            ),
          ),
      _ownsClient = client == null,
      endpoint = endpoint ?? _defaultEndpoint {
    if (this.endpoint.scheme != 'https' ||
        this.endpoint.host != 'cloudflare-dns.com' ||
        this.endpoint.path != '/dns-query' ||
        this.endpoint.query.isNotEmpty ||
        (this.endpoint.hasPort && this.endpoint.port != 443) ||
        this.endpoint.userInfo.isNotEmpty ||
        this.endpoint.hasFragment) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'endpoint is not approved',
      );
    }
  }

  static final Uri _defaultEndpoint = Uri(
    scheme: 'https',
    host: 'cloudflare-dns.com',
    path: '/dns-query',
  );

  final http.Client _client;
  final bool _ownsClient;
  final Uri endpoint;

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
    final addresses = <InternetAddress>[];
    Duration? ttl;
    Object? lastError;
    for (final type in const ['A', 'AAAA']) {
      try {
        final result = await _query(
          host,
          type,
          revision: revision,
          cancelSignal: cancelSignal,
        );
        addresses.addAll(result.addresses);
        final resultTtl = result.ttl;
        if (resultTtl != null && (ttl == null || resultTtl < ttl)) {
          ttl = resultTtl;
        }
      } on NetworkFailureException {
        rethrow;
      } on Object catch (error) {
        lastError = error;
      }
    }
    final unique = <String, InternetAddress>{
      for (final address in addresses) address.address: address,
    };
    if (unique.isEmpty) {
      final error = lastError;
      if (error != null) throw error;
      throw const SecureResolutionException('DoH returned no addresses');
    }
    return ResolvedHost(
      host: host,
      addresses: unique.values.toList(growable: false),
      dnsSource: DnsSource.doh,
      revision: revision,
      ttl: ttl ?? const Duration(seconds: 30),
    );
  }

  Future<({List<InternetAddress> addresses, Duration? ttl})> _query(
    String host,
    String type, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async {
    final uri = endpoint.replace(queryParameters: {'name': host, 'type': type});
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers['Accept'] = 'application/dns-json';
    final future = _client.send(request);
    final response = await _raceCancellation(future, cancelSignal);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      throw SecureResolutionException('DoH HTTP ${response.statusCode}');
    }
    final bytes = await _raceCancellation(
      response.stream.toBytes(),
      cancelSignal,
    );
    if (bytes.length > 64 * 1024) {
      throw const SecureResolutionException('DoH response too large');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> || decoded['Status'] != 0) {
      throw const SecureResolutionException('DoH response status failed');
    }
    final answers = decoded['Answer'];
    if (answers is! List) {
      throw const SecureResolutionException('DoH response has no answers');
    }
    final found = <InternetAddress>[];
    Duration? minTtl;
    for (final raw in answers) {
      if (raw is! Map<String, dynamic>) continue;
      final answerName = raw['name'];
      final answerType = raw['type'];
      final data = raw['data'];
      final rawTtl = raw['TTL'];
      if (answerName is! String ||
          !_sameDnsName(answerName, host) ||
          answerType is! int ||
          data is! String ||
          rawTtl is! int ||
          rawTtl < 0 ||
          rawTtl > 86400) {
        continue;
      }
      final address = InternetAddress.tryParse(data);
      final isExpectedType =
          (type == 'A' && answerType == 1) ||
          (type == 'AAAA' && answerType == 28);
      if (!isExpectedType ||
          address == null ||
          !isPublicNetworkAddress(address)) {
        continue;
      }
      found.add(address);
      final candidateTtl = Duration(seconds: rawTtl);
      if (minTtl == null || candidateTtl < minTtl) minTtl = candidateTtl;
      if (found.length >= 8) break;
    }
    return (addresses: found, ttl: minTtl);
  }

  @override
  Future<void> dispose() async {
    if (_ownsClient) _client.close();
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

bool _sameDnsName(String answer, String expected) {
  final normalized = answer.endsWith('.')
      ? answer.substring(0, answer.length - 1)
      : answer;
  return normalized.toLowerCase() == expected;
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
