import 'dart:async';

import '../network/compat/network_contracts.dart';

/// Cooperative cancellation handle. `cancel()` is idempotent.
class DownloadCancelToken implements NetworkCancelSignal {
  final _completer = Completer<void>();
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  @override
  Future<void> get whenCancel => _completer.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _completer.complete();
  }
}

/// A streaming HTTP response opened by a [DownloadTransport].
abstract class DownloadResponse {
  int get statusCode;
  int? get contentLength;

  /// Byte stream; consumers write chunks straight to the sink (R2).
  Stream<List<int>> get stream;

  /// Stops the transfer and tears down the socket. Safe to call twice.
  Future<void> close();
}

/// Optional response metadata used for observable Retry-After handling.
/// Keeping it separate preserves compatibility with small test/platform
/// response adapters that only provide status, length and body.
abstract interface class DownloadResponseMetadata {
  Map<String, String> get headers;
}

/// Pluggable streaming transport so tests inject fakes while production uses
/// the shared pooled [HttpClient] (R1).
abstract class DownloadTransport {
  /// Opens [url]; the implementation owns redirect handling and must not
  /// auto-follow to non-allowed hosts (R7).
  Future<DownloadResponse> open(
    Uri url, {
    required Map<String, String> headers,
    required DownloadCancelToken cancelToken,
  });
}

/// Optional lifecycle contract for transports that own sockets or other
/// native resources. Fakes do not need to implement it.
abstract interface class DisposableDownloadTransport {
  Future<void> dispose();
}
