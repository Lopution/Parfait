import 'dart:io';

import '../../download/download_transport.dart';
import '../../download/pixiv_download_transport.dart';
import '../pixiv_client_identity.dart';
import 'network_contracts.dart';
import 'network_policy.dart';
import 'strict_http_client.dart';

/// Streaming Pixiv media transport backed by the same network policy as API,
/// OAuth and image-cache requests. Redirects remain manual and are validated
/// by [HttpDownloadTransport] at every hop.
class PolicyDownloadTransport
    implements DownloadTransport, DisposableDownloadTransport {
  PolicyDownloadTransport({required this.policy});

  final NetworkAccessPolicy policy;
  final Map<String, HttpDownloadTransport> _transports = {};
  final Map<String, HttpClient> _rawClients = {};

  @override
  Future<DownloadResponse> open(
    Uri url, {
    required Map<String, String> headers,
    required DownloadCancelToken cancelToken,
  }) async {
    final destination = policy.registry.require(
      url,
      PixivDestinationPurpose.image,
    );
    return policy.runLadder<DownloadResponse>(
      destination: destination,
      cancelSignal: cancelToken,
      // A download is a streamed GET with no body; a repeat is safe. The
      // ladder itself enforces eligibility (transport failures only).
      canReplay: true,
      attempt: (route, routeUrl) async {
        try {
          return await _transportFor(route).open(
            routeUrl,
            headers: headers,
            cancelToken: cancelToken,
          );
        } on DownloadTransportException catch (error, stackTrace) {
          // The ladder classifies what attempt throws; the transitive
          // cause carries the real transport error (e.g. SocketException).
          // When it is fallback-eligible, drive the ladder with the cause
          // (same observable network class downstream); otherwise keep the
          // original wrapper so cancellation/HTTP semantics stay intact.
          final cause = error.cause;
          if (cause != null &&
              TransportFailureClassifier.isFallbackEligible(cause)) {
            Error.throwWithStackTrace(cause, stackTrace);
          }
          rethrow;
        }
      },
    );
  }

  HttpDownloadTransport _transportFor(NetworkRoute route) {
    return _transports.putIfAbsent(route.key, () {
      final rawClient = NativeStrictConnector.create(route);
      _rawClients[route.key] = rawClient;
      return HttpDownloadTransport(
        client: rawClient,
        allowedHosts: PixivClientIdentity.downloadHosts,
        requireHttps: true,
      );
    });
  }

  @override
  Future<void> dispose() async {
    final transports = _transports.values.toList(growable: false);
    final clients = _rawClients.values.toList(growable: false);
    _transports.clear();
    _rawClients.clear();
    for (final transport in transports) {
      await transport.dispose();
    }
    for (final client in clients) {
      client.close(force: true);
    }
  }
}
