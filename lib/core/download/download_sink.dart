import 'dart:async';

import '../platform/android_platform_interfaces.dart';
import '../platform/saf_tree.dart';
import 'download_destination.dart';
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
  Future<DownloadSink> begin(
    DownloadRequest request,
    String displayName, {
    DownloadDestination destination = DownloadDestination.builtin,
  });
}

/// Optional extension for factories that can register the opaque owner with
/// the platform output before the first byte is written. Legacy/unit
/// factories remain valid and are still fenced by the manager's metadata.
abstract interface class OwnedDownloadSinkFactory {
  Future<DownloadSink> beginOwned(
    DownloadRequest request,
    String displayName,
    DownloadOutputOwner owner, {
    DownloadDestination destination = DownloadDestination.builtin,
  });
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
  Future<DownloadSink> begin(
    DownloadRequest request,
    String displayName, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) => _begin(request, displayName, destination);

  @override
  Future<DownloadSink> beginOwned(
    DownloadRequest request,
    String displayName,
    DownloadOutputOwner owner, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) async {
    final handle = _session is OwnedMediaStoreSession
        ? await (_session as OwnedMediaStoreSession).beginOwned(
            displayName: displayName,
            mimeType: request.mimeType,
            owner: owner,
            relativePath: _relativePathFor(destination),
          )
        : await _session.begin(
            displayName: displayName,
            mimeType: request.mimeType,
            relativePath: _relativePathFor(destination),
          );
    return _MediaStoreSink(handle);
  }

  Future<DownloadSink> _begin(
    DownloadRequest request,
    String displayName,
    DownloadDestination destination,
  ) async {
    final handle = await _session.begin(
      displayName: displayName,
      mimeType: request.mimeType,
      relativePath: _relativePathFor(destination),
    );
    return _MediaStoreSink(handle);
  }

  /// D5: built-in album is the platform default; a custom album adds one
  /// `Pictures/<name>` segment after platform-side normalization.
  static String? _relativePathFor(DownloadDestination destination) {
    return switch (destination.kind) {
      DownloadDestinationKind.pixivAlbum => null,
      DownloadDestinationKind.customAlbum =>
        'Pictures/${destination.customAlbumName ?? 'PixivFunc'}',
      DownloadDestinationKind.safFolder => null,
    };
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
    String displayName, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) async {
    final sink = MemorySink();
    sinks.add(sink);
    return sink;
  }

  @override
  Future<DownloadSink> beginOwned(
    DownloadRequest request,
    String displayName,
    DownloadOutputOwner owner, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) => begin(request, displayName, destination: destination);
}

/// SAF-backed sink writing into a persisted tree URI (D5).
class SafDownloadSink implements DownloadSink {
  SafDownloadSink(this._doc, {required this.owner});

  final SafDocumentSink _doc;
  final DownloadOutputOwner? owner;
  bool _closed = false;

  @override
  Future<void> write(List<int> bytes) {
    if (_closed) throw StateError('saf sink is closed');
    return _doc.write(bytes);
  }

  @override
  Future<String> finalize() async {
    if (_closed) throw StateError('saf sink is closed');
    await _doc.close();
    _closed = true;
    // A SAF document has no MediaStore pending row; the document URI itself
    // is the durable result once the stream closes.
    return _doc.uri;
  }

  @override
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    // Best effort: remove the document so cancellation/failure cannot leave a
    // partial file in the user's selected tree.
    try {
      await _doc.close();
    } on Object {
      // Cleanup must never mask the original failure.
    }
    try {
      await _doc.delete();
    } on Object {
      // Cleanup must never mask the original failure.
    }
  }
}

/// Routes one submission to the MediaStore album path or the SAF tree path
/// based on the persisted destination (D5). The requested target is
/// normalized once here; neither path accepts raw filesystem paths.
class DestinationAwareSinkFactory
    implements DownloadSinkFactory, OwnedDownloadSinkFactory {
  DestinationAwareSinkFactory({
    required MediaStoreSinkFactory mediaStore,
    required SafDocumentSinkFactory saf,
  }) : _mediaStore = mediaStore,
       _saf = saf;

  final MediaStoreSinkFactory _mediaStore;
  final SafDocumentSinkFactory _saf;

  @override
  Future<DownloadSink> begin(
    DownloadRequest request,
    String displayName, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) {
    if (destination.isSafFolder) {
      return _beginSaf(request, displayName, null, destination);
    }
    return _mediaStore.begin(request, displayName, destination: destination);
  }

  @override
  Future<DownloadSink> beginOwned(
    DownloadRequest request,
    String displayName,
    DownloadOutputOwner owner, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) {
    if (destination.isSafFolder) {
      return _beginSaf(request, displayName, owner, destination);
    }
    return _mediaStore.beginOwned(
      request,
      displayName,
      owner,
      destination: destination,
    );
  }

  Future<DownloadSink> _beginSaf(
    DownloadRequest request,
    String displayName,
    DownloadOutputOwner? owner,
    DownloadDestination effective,
  ) async {
    final doc = await _saf.create(
      treeUri: effective.safTreeUri ?? '',
      displayName: displayName,
      mimeType: request.mimeType,
      owner: owner,
    );
    return SafDownloadSink(doc, owner: owner);
  }
}
