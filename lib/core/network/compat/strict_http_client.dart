import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'network_contracts.dart';

/// Creates a native client for one already-selected route.
///
/// Secure-DNS steering changes only the TCP destination. The `HttpClient`
/// still receives the original HTTPS URI, so Dart owns the original SNI,
/// certificate hostname check and HTTP Host header. No certificate callback,
/// SNI override or Host rewrite is installed here.
abstract final class NativeStrictConnector {
  static HttpClient create(
    NetworkRoute route, {
    Duration idleTimeout = const Duration(seconds: 30),
  }) {
    if (route.kind != NetworkRouteKind.direct &&
        route.kind != NetworkRouteKind.secureDns) {
      throw ArgumentError.value(route.kind, 'route', 'route is not native');
    }
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
        // destination is steered to the resolver candidate.
        return Socket.startConnect(address, url.port);
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
