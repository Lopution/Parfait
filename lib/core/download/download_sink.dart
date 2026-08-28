import 'dart:async';

import '../platform/android_platform_interfaces.dart';
import 'download_recovery.dart';
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

/// Optional extension for factories that can register the opaque owner with
/// the platform output before the first byte is written. Legacy/unit
/// factories remain valid and are still fenced by the manager's metadata.
abstract interface class OwnedDownloadSinkFactory {
  Future<DownloadSink> beginOwned(
    DownloadRequest request,
    String displayName,
    DownloadOutputOwner owner,
  );
}

/// Optional sink metadata used to persist/recover a pending platform row.
abstract interface class DownloadSinkOutputMetadata {
  int? get pendingOutputId;
}

/// Optional factory capability for process-restart orphan cleanup.
abstract interface class RecoverableDownloadSinkFactory {
  Future<List<PendingMediaStoreItem>> listPending();

  /// Returns false when the platform safely refused because the row was
  /// missing or carried a different owner marker.
  Future<bool> cleanupPending(int id, {required DownloadOutputOwner owner});
}

/// MediaStore-backed sink factory writing into Pictures/PixivFunc via the
/// platform session (android-platform-parity contract).
class MediaStoreSinkFactory
    implements
        DownloadSinkFactory,
        OwnedDownloadSinkFactory,
        RecoverableDownloadSinkFactory {
  MediaStoreSinkFactory(this._session);

  final MediaStoreSession _session;

  @override
  Future<DownloadSink> begin(DownloadRequest request, String displayName) =>
      _begin(request, displayName);

  @override
  Future<DownloadSink> beginOwned(
    DownloadRequest request,
    String displayName,
    DownloadOutputOwner owner,
  ) async {
    final handle = _session is OwnedMediaStoreSession
        ? await (_session as OwnedMediaStoreSession).beginOwned(
            displayName: displayName,
            mimeType: request.mimeType,
            owner: owner,
          )
        : await _session.begin(
            displayName: displayName,
            mimeType: request.mimeType,
          );
    return _MediaStoreSink(handle);
  }

  Future<DownloadSink> _begin(
    DownloadRequest request,
    String displayName,
  ) async {
    final handle = await _session.begin(
      displayName: displayName,
      mimeType: request.mimeType,
    );
    return _MediaStoreSink(handle);
  }

  @override
  Future<List<PendingMediaStoreItem>> listPending() async {
    if (_session is! RecoverableMediaStoreSession) return const [];
    return (_session as RecoverableMediaStoreSession).listPending();
  }

  @override
  Future<bool> cleanupPending(
    int id, {
    required DownloadOutputOwner owner,
  }) async {
    if (_session is! RecoverableMediaStoreSession) {
      throw StateError('pending output recovery is unsupported');
    }
    return (_session as RecoverableMediaStoreSession).abortPending(
      id,
      ownerId: owner.ownerId,
    );
  }
}

class _MediaStoreSink implements DownloadSink, DownloadSinkOutputMetadata {
  _MediaStoreSink(this._handle);

  final MediaStoreHandle _handle;
  bool _finished = false;
  bool _finalizing = false;

  @override
  int? get pendingOutputId => _finished ? null : _handle.id;

  @override
  Future<void> write(List<int> bytes) => _handle.write(bytes);

  @override
  Future<String> finalize() async {
    if (_finished || _finalizing) {
      throw StateError('sink already finalized or aborted');
    }
    _finalizing = true;
    try {
      final uri = await _handle.finalize();
      _finished = true;
      return uri.toString();
    } finally {
      _finalizing = false;
    }
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
class MemorySinkFactory
    implements DownloadSinkFactory, OwnedDownloadSinkFactory {
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

  @override
  Future<DownloadSink> beginOwned(
    DownloadRequest request,
    String displayName,
    DownloadOutputOwner owner,
  ) => begin(request, displayName);
}
