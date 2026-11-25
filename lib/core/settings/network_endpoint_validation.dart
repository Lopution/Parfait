import 'dart:io';

/// Pure validators for user-configured DoH endpoint URLs and ECH front hosts.
///
/// Shared across [AppSettings], [SettingsController], [DohResolver], and the
/// network settings UI so storage, runtime resolution, and form input enforce
/// the same HTTPS and host rules.

final RegExp _asciiDnsLabel = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');

/// Whether [rawHost] names localhost, a loopback address (IPv4 `127.0.0.0/8`,
/// IPv6 `::1`, or IPv4-mapped `::ffff:127.0.0.0/104`), or the unspecified
/// address (`0.0.0.0` / `::`).
bool isLoopbackOrLocalhostHost(String rawHost) {
  var host = rawHost.trim().toLowerCase();
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host.isEmpty) return true;
  if (host == 'localhost' || host.endsWith('.localhost')) return true;

  final address = InternetAddress.tryParse(host);
  if (address == null) return false;
  if (address.isLoopback) return true;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
    return bytes[0] == 127 || bytes[0] == 0;
  }
  if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
    final allZero = bytes.every((b) => b == 0);
    if (allZero) return true;
    // IPv4-mapped IPv6 (`::ffff:a.b.c.d`).
    var mappedPrefix = true;
    for (var i = 0; i < 10; i++) {
      if (bytes[i] != 0) {
        mappedPrefix = false;
        break;
      }
    }
    if (mappedPrefix && bytes[10] == 0xff && bytes[11] == 0xff) {
      return bytes[12] == 127 || bytes[12] == 0;
    }
  }
  return false;
}

bool _isValidAsciiDnsHost(String host) {
  if (host.isEmpty || host.length > 253) return false;
  if (host.startsWith('.') || host.endsWith('.') || host.contains('..')) {
    return false;
  }
  final labels = host.split('.');
  if (labels.length < 2) return false;
  for (final label in labels) {
    if (!_asciiDnsLabel.hasMatch(label)) return false;
  }
  return true;
}

/// Validates a single DoH endpoint URL.
///
/// Requires `https://`, empty userInfo, no fragment, and a non-loopback ASCII
/// DNS hostname or IP literal (public or permitted LAN IPv4/IPv6).
Uri? validateDohEndpointUri(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.codeUnits.any((c) => c <= 0x20 || c == 0x7f)) {
    return null;
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (isLoopbackOrLocalhostHost(host)) return null;
  final isIpLiteral = InternetAddress.tryParse(host) != null;
  if (!isIpLiteral && !_isValidAsciiDnsHost(host)) return null;
  return uri;
}

/// Splits a comma-separated DoH override string into validated endpoint URLs.
///
/// Returns an empty list if [raw] is null, empty, comma-only, or contains any
/// invalid endpoint entry.
List<String> parseDohEndpointList(String? raw) {
  if (raw == null) return const [];
  final entries = raw
      .split(',')
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList(growable: false);
  if (entries.isEmpty) return const [];
  for (final entry in entries) {
    if (validateDohEndpointUri(entry) == null) return const [];
  }
  return entries;
}

/// Normalizes a comma-separated DoH override string, or returns `null` when
/// empty, comma-only, or containing any invalid endpoint.
String? normalizeDohEndpointOverride(String? raw) {
  final parsed = parseDohEndpointList(raw);
  return parsed.isEmpty ? null : parsed.join(', ');
}

/// Normalizes an ECH front hostname to lowercase ASCII DNS, rejecting IP
/// literals, `localhost`, and malformed hostnames.
String? normalizeEchFrontHost(String? raw) {
  if (raw == null) return null;
  final host = raw.trim().toLowerCase();
  if (host.isEmpty || isLoopbackOrLocalhostHost(host)) return null;
  if (InternetAddress.tryParse(host) != null) return null;
  if (!_isValidAsciiDnsHost(host)) return null;
  return host;
}

/// Reads and validates `dohEndpointOverride` from persisted settings JSON,
/// keeping [fallback] on malformed values (PREF-01).
String? readDohEndpointOverride(Map<String, dynamic> json, String? fallback) {
  if (!json.containsKey('dohEndpointOverride')) return fallback;
  final raw = json['dohEndpointOverride'];
  if (raw == null) return null;
  if (raw is! String) return fallback;
  if (raw.trim().isEmpty) return null;
  return normalizeDohEndpointOverride(raw) ?? fallback;
}

/// Reads and validates `echFrontHost` from persisted settings JSON,
/// keeping [fallback] on malformed values (PREF-01).
String readEchFrontHost(Map<String, dynamic> json, String fallback) {
  final raw = json['echFrontHost'];
  if (raw is! String) return fallback;
  return normalizeEchFrontHost(raw) ?? fallback;
}
