import 'dart:async';
import 'dart:io';

import 'network_contracts.dart';

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
