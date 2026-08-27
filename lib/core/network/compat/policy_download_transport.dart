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
    final direct = NetworkRoute.direct(policy.revision);
    final directTimer = Stopwatch()..start();
    try {
      return await _transportFor(direct).open(
        url,
        headers: headers,
        cancelToken: cancelToken,
      );
    } on Object catch (error, stackTrace) {
      final diagnosticError = _underlyingError(error);
      policy.recordFailure(
        host: destination.canonicalHost,
        purpose: PixivDestinationPurpose.image,
        route: direct,
        error: diagnosticError,
        latency: directTimer.elapsed,
      );
      if (policy.mode == NetworkMode.directOnly ||
          !TransportFailureClassifier.isFallbackEligible(diagnosticError)) {
        Error.throwWithStackTrace(error, stackTrace);
      }

      final resolved = await policy.resolve(
        destination,
        cancelSignal: cancelToken,
      );
      Object lastError = error;
      StackTrace lastStack = stackTrace;
      for (final address in resolved.addresses) {
        final route = NetworkRoute.secureDns(
          policy.revision,
          address,
          dnsSource: resolved.dnsSource,
          ttl: resolved.ttl,
        );
        final candidateTimer = Stopwatch()..start();
        try {
          return await _transportFor(route).open(
            url,
            headers: headers,
            cancelToken: cancelToken,
          );
        } on Object catch (candidateError, candidateStack) {
          final candidateDiagnostic = _underlyingError(candidateError);
          policy.recordFailure(
            host: destination.canonicalHost,
            purpose: PixivDestinationPurpose.image,
            route: route,
            error: candidateDiagnostic,
            latency: candidateTimer.elapsed,
          );
          lastError = candidateError;
          lastStack = candidateStack;
          if (!TransportFailureClassifier.isFallbackEligible(
            candidateDiagnostic,
          )) {
            break;
          }
        }
      }
      Error.throwWithStackTrace(lastError, lastStack);
    }
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

Object _underlyingError(Object error) {
  if (error is DownloadTransportException && error.cause != null) {
    return error.cause!;
  }
  if (error is DownloadCancelledException) {
    return const NetworkFailureException(NetworkFailureKind.cancelled);
  }
  return error;
}
