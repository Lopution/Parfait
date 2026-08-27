import 'dart:async';
import 'dart:io';

import '../network/pixiv_client_identity.dart';
import 'download_transport.dart';

/// One raw HTTP hop as observed by the redirect loop. Extracted so the
/// hop-policy (allowlist, https, redirect limit, status handling) is unit
/// testable without sockets; production wraps `dart:io`.
abstract class RawHop {
  int get statusCode;

  /// `Location` header value, when present.
  String? get locationHeader;

  int? get contentLength;

  /// Single-use body stream.
  Stream<List<int>> get body;

  /// Consumes body + done so the underlying connection ends in a defined
  /// state. Must complete even for empty bodies.
  Future<void> drain();

  /// Tears the underlying connection/request down (cancel path).
  void abort();
}

/// Production transport over a shared pooled `HttpClient` (R1). Redirects
/// are followed manually so every hop is validated against the download
/// host allowlist (R7). TLS failures propagate; there is no certificate
/// bypass anywhere.
class HttpDownloadTransport
    implements DownloadTransport, DisposableDownloadTransport {
  /// [allowedHosts]/[requireHttps] default to the production security
  /// policy; tests inject loopback values. Nothing at runtime may widen
  /// them.
  HttpDownloadTransport({
    HttpClient? client,
    this.maxRedirects = 5,
    Set<String>? allowedHosts,
    this.requireHttps = true,
  })  : _ownsClient = client == null,
        client = client ?? HttpClient(),
        allowedHosts = allowedHosts ?? PixivClientIdentity.downloadHosts;

  final HttpClient client;
  final int maxRedirects;
  final Set<String> allowedHosts;
  final bool requireHttps;
  final bool _ownsClient;

  bool isAllowedHost(String host) => allowedHosts.contains(host.toLowerCase());

  @override
  Future<DownloadResponse> open(
    Uri url, {
    required Map<String, String> headers,
    required DownloadCancelToken cancelToken,
  }) async {
    var current = url;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      _validateUrl(current);
      if (cancelToken.isCancelled) {
        throw const DownloadCancelledException();
      }
      final RawHop hopResponse;
      try {
        hopResponse = await openHop(current, headers, cancelToken);
      } on HttpException catch (error) {
        if (cancelToken.isCancelled) {
          throw const DownloadCancelledException();
        }
        throw DownloadTransportException('request failed', cause: error);
      }
      if (cancelToken.isCancelled) {
        hopResponse.abort();
        throw const DownloadCancelledException();
      }

      final status = hopResponse.statusCode;
      if (status >= 300 && status < 400) {
        final location = hopResponse.locationHeader;
        await hopResponse.drain();
        if (location == null) {
          throw const DownloadTransportException('redirect without location');
        }
        if (hop == maxRedirects) {
          throw const DownloadTransportException('too many redirects');
        }
        final next = current.resolve(location);
        // R7: each hop must stay on the allowlist, https only.
        _validateUrl(next);
        current = next;
        continue;
      }
      if (status < 200 || status >= 300) {
        await hopResponse.drain();
        throw DownloadHttpStatusException(status, current);
      }
      return HopDownloadResponse(hopResponse, cancelToken: cancelToken);
    }
    throw const DownloadTransportException('unreachable redirect loop');
  }

  /// Opens one hop. Tests subclass and script hops deterministically.
  Future<RawHop> openHop(
    Uri url,
    Map<String, String> headers,
    DownloadCancelToken cancelToken,
  ) async {
    final HttpClientRequest request;
    try {
      request = await client.getUrl(url);
    } on Object catch (error) {
      if (cancelToken.isCancelled) {
        throw const DownloadCancelledException();
      }
      throw DownloadTransportException('request setup failed', cause: error);
    }
    request.followRedirects = false;
    request.maxRedirects = 0;
    headers.forEach(request.headers.set);
    // Cancel before/while the request is in flight aborts the socket.
    unawaited(cancelToken.whenCancel.then((_) {
      try {
        request.abort();
      } on StateError {
        // Already sent/response received; close() handles teardown.
      } on HttpException {
        // Socket already gone; nothing to abort.
      }
    }));
    if (cancelToken.isCancelled) {
      request.abort();
      throw const DownloadCancelledException();
    }
    final HttpClientResponse response;
    try {
      response = await request.close();
    } on Object catch (error) {
      if (cancelToken.isCancelled) {
        throw const DownloadCancelledException();
      }
      throw DownloadTransportException('request failed', cause: error);
    }
    final lengthHeader = response.contentLength;
    return _IoHop(
      response,
      contentLength: lengthHeader >= 0 ? lengthHeader : null,
      onAbort: () {
        try {
          request.abort();
        } on HttpException {
          // Socket already gone; nothing to abort.
        } on StateError {
          // Request already finished; nothing to abort.
        }
      },
    );
  }

  void _validateUrl(Uri url) {
    if (requireHttps && url.scheme != 'https') {
      throw const DownloadTransportException('download URL must be https');
    }
    if (!isAllowedHost(url.host)) {
      throw DownloadTransportException(
        'download host not allowed: ${url.host}',
      );
    }
    if (url.userInfo.isNotEmpty) {
      throw const DownloadTransportException('userinfo in download URL');
    }
    if (url.hasFragment) {
      throw const DownloadTransportException('fragment in download URL');
    }
  }

  @override
  Future<void> dispose() async {
    if (_ownsClient) {
      client.close(force: true);
    }
  }
}

class _IoHop implements RawHop {
  _IoHop(
    this._response, {
    required int? contentLength,
    required void Function() onAbort,
  })  : _contentLength = contentLength,
        _onAbort = onAbort;

  final HttpClientResponse _response;
  final int? _contentLength;
  final void Function() _onAbort;

  @override
  int get statusCode => _response.statusCode;

  @override
  String? get locationHeader =>
      _response.headers.value(HttpHeaders.locationHeader);

  @override
  int? get contentLength => _contentLength;

  @override
  Stream<List<int>> get body => _response;

  @override
  Future<void> drain() => _response.drain<void>();

  @override
  void abort() => _onAbort();
}

/// DownloadResponse over a RawHop with cancel injection: whenCancel produces
/// an error event so consumers always terminate, even when the platform
/// keeps the idle socket open.
class HopDownloadResponse implements DownloadResponse {
  HopDownloadResponse(this._hop, {required DownloadCancelToken cancelToken})
      : _cancelToken = cancelToken {
    unawaited(_cancelToken.whenCancel.then((_) {
      _cancelled = true;
      _hop.abort();
    }));
  }

  final RawHop _hop;
  final DownloadCancelToken _cancelToken;
  bool _cancelled = false;

  @override
  int? get contentLength => _hop.contentLength;

  @override
  int get statusCode => _hop.statusCode;

  @override
  Stream<List<int>> get stream {
    if (_cancelled) {
      throw const DownloadCancelledException();
    }
    late StreamController<List<int>> controller;
    StreamSubscription<List<int>>? sub;
    controller = StreamController<List<int>>(
      onListen: () {
        sub = _hop.body.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        unawaited(_cancelToken.whenCancel.then((_) {
          _hop.abort();
          controller.addError(const DownloadCancelledException());
          unawaited(sub?.cancel());
          unawaited(controller.close());
        }));
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () => sub?.cancel(),
    );
    return controller.stream;
  }

  @override
  Future<void> close() {
    _cancelled = true;
    _hop.abort();
    return Future.value();
  }
}

class DownloadCancelledException implements Exception {
  const DownloadCancelledException();
}

class DownloadTransportException implements Exception {
  const DownloadTransportException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'DownloadTransportException: $message';
}

class DownloadHttpStatusException implements Exception {
  const DownloadHttpStatusException(this.statusCode, this.url);

  final int statusCode;
  final Uri url;

  @override
  String toString() =>
      'DownloadHttpStatusException: HTTP $statusCode for $url';
}
