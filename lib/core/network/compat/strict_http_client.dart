import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'network_contracts.dart';

/// Creates a native client for one already-selected route.
///
/// Secure-DNS steering changes only the TCP destination. The `HttpClient`
/// still receives the original HTTPS URI, so Dart owns the original SNI,
/// certificate hostname check and HTTP Host header.
///
/// IMPORTANT (pinned by test/tls_sni_behaviour_test.dart): when
/// `connectionFactory` is set and the request is direct, Dart's HttpClient
/// uses the returned socket as-is and skips TLS entirely. The factory must
/// therefore wrap the steered raw socket in `SecureSocket.secure` with the
/// URL's real hostname — that keeps SNI, chain verification and hostname
/// verification intact while the TCP peer is the resolver-chosen IP.
abstract final class NativeStrictConnector {
  static HttpClient create(
    NetworkRoute route, {
    Duration idleTimeout = const Duration(seconds: 30),
  }) {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.idleTimeout = idleTimeout;
    if (route.kind == NetworkRouteKind.secureDns) {
      final address = route.address;
      if (address == null) {
        client.close(force: true);
        throw ArgumentError('secure DNS route has no address');
      }
      client.connectionFactory = (url, proxyHost, proxyPort) {
        if (proxyHost != null || proxyPort != null) {
          throw const SocketException('proxy route rejected');
        }
        // The URI passed to HttpClient remains `url`; only this socket's
        // destination is steered to the resolver candidate. The steered
        // socket must then be upgraded to TLS explicitly (see the class
        // doc): without the SecureSocket wrapper the SDK would send the
        // request in plaintext to port 443.
        return Socket.startConnect(address, url.port).then(
          (rawTask) => ConnectionTask.fromSocket<Socket>(
            rawTask.socket.then<Socket>(
              (socket) => SecureSocket.secure(socket, host: url.host),
            ),
            rawTask.cancel,
          ),
        );
      };
    }
    return client;
  }
}

/// `http.Client` adapter used by the shared policy and cache manager.
class StrictHttpClientFactory {
  const StrictHttpClientFactory();

  http.Client create(NetworkRoute route) {
    return IOClient(NativeStrictConnector.create(route));
  }
}
