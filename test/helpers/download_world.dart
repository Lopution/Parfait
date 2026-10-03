import 'dart:async';

import 'package:parfait/core/download/download_transport.dart';
import 'package:parfait/core/download/pixiv_download_transport.dart'
    show DownloadCancelledException;

/// Scripted transport: each open() pops the next [ScriptedResponse].
class FakeTransport implements DownloadTransport {
  final responses = <ScriptedResponse>[];
  final openedUrls = <Uri>[];
  final activeResponses = <_FakeResponse>[];

  @override
  Future<DownloadResponse> open(
    Uri url, {
    required Map<String, String> headers,
    required DownloadCancelToken cancelToken,
  }) async {
    openedUrls.add(url);
    final response = _FakeResponse(responses.removeAt(0), cancelToken);
    activeResponses.add(response);
    return response;
  }
}

class ScriptedResponse {
  ScriptedResponse({
    this.statusCode = 200,
    this.contentLength,
    this.chunks = const [],
    this.completers,
    this.error,
  });

  final int statusCode;
  final int? contentLength;
  final List<List<int>> chunks;

  /// When non-null, chunk [i] is gated behind completers[i]; the stream
  /// only completes when tests flush it.
  final List<Completer<void>>? completers;
  final Object? error;
}

class _FakeResponse implements DownloadResponse {
  _FakeResponse(this.script, this.cancelToken);

  final ScriptedResponse script;
  final DownloadCancelToken cancelToken;
  final _closed = Completer<void>();

  @override
  int get statusCode => script.statusCode;

  @override
  int? get contentLength => script.contentLength;

  @override
  Stream<List<int>> get stream {
    if (script.error != null) {
      return Stream<List<int>>.error(script.error!);
    }
    final completers = script.completers;
    var index = 0;
    final controller = StreamController<List<int>>();
    Future<void> drain() async {
      try {
        for (final chunk in script.chunks) {
          if (cancelToken.isCancelled) {
            await close();
            controller.addError(const DownloadCancelledException());
            return;
          }
          final gate = completers == null ? null : completers[index++];
          if (gate != null) {
            await gate.future;
          }
          if (cancelToken.isCancelled) {
            await close();
            controller.addError(const DownloadCancelledException());
            return;
          }
          controller.add(chunk);
          // Yield so the consumer's await for actually progresses.
          await Future<void>.delayed(Duration.zero);
        }
        await controller.close();
      } catch (error) {
        controller.addError(error);
        await controller.close();
      }
    }

    unawaited(drain());
    return controller.stream;
  }

  @override
  Future<void> close() {
    if (!_closed.isCompleted) {
      _closed.complete();
    }
    return _closed.future;
  }
}
