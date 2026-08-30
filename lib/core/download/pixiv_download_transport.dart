import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../network/pixiv_client_identity.dart';
import 'download_transport.dart';
import 'download_request.dart';

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

abstract interface class RawHopHeaders {
  Map<String, String> get headers;
}

/// Production transport over a shared pooled `http.Client` (R1: rhttp).
/// Redirects are followed manually so every hop is validated against the
/// download host allowlist (R7). TLS failures propagate; certificate
/// verification is owned by the client factory (policy tier), never bypassed
/// here.
class HttpDownloadTransport
    implements DownloadTransport, DisposableDownloadTransport {
  /// [allowedHosts]/[requireHttps] default to the production security
  /// policy; tests inject loopback values. Nothing at runtime may widen
  /// them. [httpClient] is the `package:http` client (rhttp in production,
  /// IOClient in tests); [fallbackConnectTimeout] is only honored by the
  /// dart:io path used by tests.
  HttpDownloadTransport({
    http.Client? httpClient,
    this.maxRedirects = 5,
    Set<String>? allowedHosts,
    this.requireHttps = true,
    this.strictUrlPolicy = false,
  }) : _ownsClient = httpClient == null,
       httpClient = httpClient ?? http.Client(),
       allowedHosts = allowedHosts ?? PixivClientIdentity.downloadHosts;

  final http.Client httpClient;
  final int maxRedirects;
  final Set<String> allowedHosts;
  final bool requireHttps;

  /// When true, every redirect must remain a signed updater APK URL. This is
  /// intentionally opt-in so legacy Pixiv image transports keep their own
  /// destination contract.
  final bool strictUrlPolicy;
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
        throw DownloadHttpStatusException(
          status,
          current,
          retryAfter: _retryAfter(hopResponse),
        );
      }
      return HopDownloadResponse(hopResponse, cancelToken: cancelToken);
    }
    throw const DownloadTransportException('unreachable redirect loop');
  }

  /// Opens one hop via the pooled [httpClient]. Tests subclass and script
  /// hops deterministically. The request is an [http.AbortableRequest] so
  /// cancellation tears the underlying socket down (rhttp maps abortTrigger
  /// to its CancelToken; dart:io IOClient maps it to request.abort).
  Future<RawHop> openHop(
    Uri url,
    Map<String, String> headers,
    DownloadCancelToken cancelToken,
  ) async {
    final request = http.Request('GET', url);
    request.headers.addAll(headers);
    request.followRedirects = false;

    final abortTrigger = Completer<void>();
    unawaited(
      cancelToken.whenCancel.then((_) {
        if (!abortTrigger.isCompleted) abortTrigger.complete();
      }),
    );
    final abortable = http.AbortableRequest(
      request.method,
      request.url,
      abortTrigger: abortTrigger.future,
    )
      ..headers.addAll(request.headers)
      ..followRedirects = false
      ..bodyBytes = request.bodyBytes;

    if (cancelToken.isCancelled) {
      throw const DownloadCancelledException();
    }

    final http.StreamedResponse response;
    try {
      response = await httpClient.send(abortable);
    } on Object catch (error) {
      if (cancelToken.isCancelled) {
        throw const DownloadCancelledException();
      }
      throw DownloadTransportException('request failed', cause: error);
    }
    if (cancelToken.isCancelled) {
      response.stream.listen(null).cancel();
      throw const DownloadCancelledException();
    }
    final lengthHeader = response.contentLength;
    return _HttpHop(
      response,
      contentLength: lengthHeader,
      onAbort: () {
        if (!abortTrigger.isCompleted) abortTrigger.complete();
      },
    );
  }

  void _validateUrl(Uri url) {
    if (strictUrlPolicy && !isStrictUpdateAssetUrl(url)) {
      throw const DownloadTransportException('strict download URL rejected');
    }
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
      httpClient.close();
    }
  }
}

class _HttpHop implements RawHop, RawHopHeaders {
  _HttpHop(
    this._response, {
    required int? contentLength,
    required void Function() onAbort,
  }) : _contentLength = contentLength,
       _onAbort = onAbort;

  final http.StreamedResponse _response;
  final int? _contentLength;
  final void Function() _onAbort;
  bool _drained = false;

  @override
  int get statusCode => _response.statusCode;

  @override
  String? get locationHeader => _response.headers['location'];

  @override
  Map<String, String> get headers {
    final result = <String, String>{};
    _response.headers.forEach((name, value) {
      result[name] = value;
    });
    return result;
  }

  @override
  int? get contentLength => _contentLength;

  @override
  Stream<List<int>> get body => _response.stream;

  @override
  Future<void> drain() {
    if (_drained) return Future.value();
    _drained = true;
    return _response.stream.drain<void>();
  }

  @override
  void abort() => _onAbort();
}

/// DownloadResponse over a RawHop with cancel injection: whenCancel produces
/// an error event so consumers always terminate, even when the platform
/// keeps the idle socket open.
class HopDownloadResponse
    implements DownloadResponse, DownloadResponseMetadata {
  HopDownloadResponse(this._hop, {required DownloadCancelToken cancelToken})
    : _cancelToken = cancelToken {
    unawaited(
      _cancelToken.whenCancel.then((_) {
        _requestCancellation();
      }),
    );
  }

  final RawHop _hop;
  final DownloadCancelToken _cancelToken;
  bool _cancelled = false;
  bool _sourceStopped = false;
  bool _stopRequested = false;
  StreamController<List<int>>? _controller;
  StreamSubscription<List<int>>? _sourceSubscription;
  Future<void>? _sourceCancellation;

  @override
  int? get contentLength => _hop.contentLength;

  @override
  int get statusCode => _hop.statusCode;

  @override
  Map<String, String> get headers =>
      _hop is RawHopHeaders ? (_hop as RawHopHeaders).headers : const {};

  @override
  Stream<List<int>> get stream {
    if (_cancelled) {
      throw const DownloadCancelledException();
    }
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        _controller = controller;
        if (_cancelled) {
          _requestCancellation();
          return;
        }
        _sourceSubscription = _hop.body.listen(
          _addSourceData,
          onError: _addSourceError,
          onDone: _closeFromSource,
        );
      },
      onPause: () => _sourceSubscription?.pause(),
      onResume: () => _sourceSubscription?.resume(),
      onCancel: () {
        _sourceStopped = true;
        return _cancelSource();
      },
    );
    _controller = controller;
    return controller.stream;
  }

  @override
  Future<void> close() {
    _cancelled = true;
    _stopRequested = true;
    _sourceStopped = true;
    _abortHop();
    unawaited(_cancelSource());
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
    return Future.value();
  }

  void _requestCancellation() {
    if (_stopRequested) return;
    _stopRequested = true;
    _cancelled = true;
    _sourceStopped = true;
    _abortHop();
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      controller.addError(const DownloadCancelledException());
      unawaited(controller.close());
    }
    unawaited(_cancelSource());
  }

  void _addSourceData(List<int> data) {
    final controller = _controller;
    if (_sourceStopped || controller == null || controller.isClosed) return;
    controller.add(data);
  }

  void _addSourceError(Object error, StackTrace stackTrace) {
    final controller = _controller;
    if (_sourceStopped || controller == null || controller.isClosed) return;
    controller.addError(error, stackTrace);
  }

  void _closeFromSource() {
    if (_sourceStopped) return;
    _sourceStopped = true;
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  Future<void> _cancelSource() {
    return _sourceCancellation ??= _cancelSourceOnce();
  }

  Future<void> _cancelSourceOnce() async {
    try {
      await _sourceSubscription?.cancel();
    } on Object {
      // The response/socket is already being torn down; cancellation remains
      // observable through the downstream terminal event.
    }
  }

  void _abortHop() {
    try {
      _hop.abort();
    } on Object {
      // Cancellation is best effort; never let a platform/socket abort error
      // prevent the consumer from receiving its terminal cancellation event.
    }
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
  const DownloadHttpStatusException(
    this.statusCode,
    this.url, {
    this.retryAfter,
  });

  final int statusCode;
  final Uri url;
  final Duration? retryAfter;

  @override
  String toString() => 'DownloadHttpStatusException: HTTP $statusCode';
}

Duration? _retryAfter(RawHop hop) {
  if (hop is! RawHopHeaders) return null;
  String? value;
  final headers = (hop as RawHopHeaders).headers;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'retry-after') {
      value = entry.value.trim();
      break;
    }
  }
  if (value == null || value.isEmpty) return null;
  final seconds = int.tryParse(value);
  if (seconds == null || seconds < 0 || seconds > 86400) return null;
  return Duration(seconds: seconds);
}
