import 'dart:async';

/// Cooperative cancellation handle. `cancel()` is idempotent.
class DownloadCancelToken {
  final _completer = Completer<void>();
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

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
