import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'network_contracts.dart';

Future<T> raceResolverCancellation<T>(
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

void validateDnsName(String host) {
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
http.Client staticMappedDohClient(
  Map<String, List<InternetAddress>> overrides,
) {
  final client = HttpClient();
  client.findProxy = (_) => 'DIRECT';
  if (overrides.isNotEmpty) {
    client.connectionFactory = (url, proxyHost, proxyPort) {
      if (url.scheme.toLowerCase() != 'https') {
        throw const SocketException('non-https DoH endpoint rejected');
      }
      final addresses = overrides[url.host];
      if (addresses == null || addresses.isEmpty) {
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
