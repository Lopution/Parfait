import 'dart:io';

/// Whether Android 17 treats [address] as local network: an app that
/// targets 37 needs the "nearby devices" permission to reach it, and
/// without it a TCP connect hangs until it times out.
///
/// The ranges follow the platform's definition: RFC 1918, link-local,
/// CGNAT (100.64/10), multicast and broadcast; on IPv6 link-local, unique
/// local (fc00::/7) and multicast. Loopback is not local network. An
/// IPv4-mapped IPv6 address (::ffff:a.b.c.d) is judged by its IPv4 part.
bool isLocalNetworkAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (_isIPv4Mapped(bytes)) {
    return isLocalNetworkAddress(
      InternetAddress.fromRawAddress(bytes.sublist(_ipv4MappedPrefix.length)),
    );
  }
  if (address.isLoopback) return false;
  if (address.isLinkLocal || address.isMulticast) return true;
  if (address.type == InternetAddressType.IPv4) {
    final [a, b, ..._] = bytes;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127) ||
        bytes.every((byte) => byte == 255);
  }
  return (bytes[0] & 0xfe) == 0xfc;
}

const _ipv4MappedPrefix = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff];

bool _isIPv4Mapped(List<int> bytes) {
  if (bytes.length != 16) return false;
  for (var i = 0; i < _ipv4MappedPrefix.length; i++) {
    if (bytes[i] != _ipv4MappedPrefix[i]) return false;
  }
  return true;
}

/// A request to [host] stopped before connecting: the host is on the local
/// network and the app may not reach it.
class LocalNetworkBlocked implements Exception {
  const LocalNetworkBlocked(this.host);

  /// A host the user configured (image source, DoH, LLM, proxy); not
  /// secret.
  final String host;

  @override
  String toString() => 'LocalNetworkBlocked($host)';
}
