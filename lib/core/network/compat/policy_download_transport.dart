import '../../download/download_transport.dart';
import '../../download/pixiv_download_transport.dart';
import '../pixiv_client_identity.dart';
import 'network_contracts.dart';
import 'network_policy.dart';

/// Streaming Pixiv media transport backed by the same network policy as API,
/// OAuth and image-cache requests. Redirects remain manual and are validated
/// by [HttpDownloadTransport] at every hop. The underlying client is the
/// policy-owned rhttp client for each route and canonical host, so the
/// download exit shares the exact same decision and pool identity as the
/// API/image exits.
class PolicyDownloadTransport
    implements DownloadTransport, DisposableDownloadTransport {
  PolicyDownloadTransport({required this.policy});

  final NetworkAccessPolicy policy;
  final Map<String, HttpDownloadTransport> _transports = {};

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
          return await _transportFor(
            route,
            destination.canonicalHost,
          ).open(routeUrl, headers: headers, cancelToken: cancelToken);
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

  HttpDownloadTransport _transportFor(
    NetworkRoute route,
    String canonicalHost,
  ) {
    final key =
        '$canonicalHost|${route.key}|${PixivDestinationPurpose.image.name}';
    return _transports.putIfAbsent(key, () {
      // Reuse the policy-owned rhttp client.  Its identity includes the
      // canonical host, route and purpose, so DNS overrides/ECH settings can
      // never leak between i.pximg.net and s.pximg.net.
      final client = policy.clientFor(
        PixivDestinationPurpose.image,
        route,
        canonicalHost,
      );
      return HttpDownloadTransport(
        httpClient: client,
        allowedHosts: PixivClientIdentity.downloadHosts,
        requireHttps: true,
      );
    });
  }

  @override
  Future<void> dispose() async {
    final transports = _transports.values.toList(growable: false);
    _transports.clear();
    for (final transport in transports) {
      await transport.dispose();
    }
  }
}
