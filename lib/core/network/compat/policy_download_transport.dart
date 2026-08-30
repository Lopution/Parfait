import '../../download/download_transport.dart';
import '../../download/pixiv_download_transport.dart';
import '../pixiv_client_identity.dart';
import 'network_contracts.dart';
import 'network_policy.dart';
import 'rhttp_client_factory.dart';

/// Streaming Pixiv media transport backed by the same network policy as API,
/// OAuth and image-cache requests. Redirects remain manual and are validated
/// by [HttpDownloadTransport] at every hop. The underlying client is built by
/// [RhttpClientFactory] per route tier (rhttp/Rust), so the download exit
/// shares the exact same policy decision as the API exit.
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
          return await _transportFor(route, destination.canonicalHost).open(
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

  HttpDownloadTransport _transportFor(
    NetworkRoute route,
    String canonicalHost,
  ) {
    return _transports.putIfAbsent(route.key, () {
      final client = RhttpClientFactory.create(
        route,
        canonicalHost,
        // Downloads stream an unbounded body: this selects the connect-only
        // time budget so a large or slow transfer is never cut mid-body.
        PixivDestinationPurpose.image,
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
