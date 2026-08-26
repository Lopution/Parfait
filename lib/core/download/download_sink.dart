import 'dart:async';

import '../platform/android_platform_interfaces.dart';
import 'download_request.dart';

/// One pending output item. Mirrors the MediaStore pending lifecycle:
/// write chunks → finalize (visible) or abort (invisible, cleaned up).
abstract class DownloadSink {
  Future<void> write(List<int> bytes);

  /// Makes the item visible. Returns the final content URI (best effort).
  Future<String> finalize();

  /// Removes the pending item. Idempotent; must never throw through the
  /// manager's failure/cancel cleanup paths (R6).
  Future<void> abort();
}

/// Creates sinks for submitted requests (R4 naming/MIME/dir decisions live
/// in the request normalization + factory).
abstract class DownloadSinkFactory {
  Future<DownloadSink> begin(DownloadRequest request, String displayName);
}

/// MediaStore-backed sink factory writing into Pictures/PixivFunc via the
/// platform session (android-platform-parity contract).
class MediaStoreSinkFactory implements DownloadSinkFactory {
  MediaStoreSinkFactory(this._session);

  final MediaStoreSession _session;

  @override
  Future<DownloadSink> begin(
    DownloadRequest request,
    String displayName,
  ) async {
    final handle = await _session.begin(
      displayName: displayName,
      mimeType: request.mimeType,
    );
    return _MediaStoreSink(handle);
  }
}

class _MediaStoreSink implements DownloadSink {
  _MediaStoreSink(this._handle);

  final MediaStoreHandle _handle;
  bool _finished = false;

  @override
  Future<void> write(List<int> bytes) => _handle.write(bytes);

  @override
  Future<String> finalize() async {
    if (_finished) {
      throw StateError('sink already finalized or aborted');
    }
    _finished = true;
    return _handle.finalize().then((uri) => uri.toString());
  }

  @override
  Future<void> abort() async {
    if (_finished) {
      return;
    }
    _finished = true;
    try {
      await _handle.abort();
    } catch (_) {
      // R6: cleanup must not mask the original failure.
    }
  }
}

/// In-memory sink for tests and debug tooling.
class MemorySink implements DownloadSink {
  final bytes = <int>[];
  var finalized = false;
  var aborted = false;
  String? finalUri;

  @override
  Future<void> write(List<int> chunk) async {
    if (finalized || aborted) {
      throw StateError('write after close');
    }
    bytes.addAll(chunk);
  }

  @override
  Future<String> finalize() async {
    if (finalized || aborted) {
      throw StateError('sink already finalized or aborted');
    }
    finalized = true;
    finalUri = 'memory://sink';
    return finalUri!;
  }

  @override
  Future<void> abort() async {
    aborted = true;
  }
}

/// Factory handing out fresh memory sinks; records every sink for assertions.
class MemorySinkFactory implements DownloadSinkFactory {
  final sinks = <MemorySink>[];

  @override
  Future<DownloadSink> begin(
    DownloadRequest request,
    String displayName,
  ) async {
    final sink = MemorySink();
    sinks.add(sink);
    return sink;
  }
}
