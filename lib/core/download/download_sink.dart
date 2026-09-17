import 'dart:async';
import 'dart:typed_data';

import '../platform/android_platform_interfaces.dart';
import '../platform/saf_tree.dart';
import 'download_destination.dart';
import 'download_recovery.dart';
import 'download_request.dart';
import 'resume_anchor.dart';

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

/// Optional sink capability: the platform output can preserve written bytes
/// across aborts so a later attempt appends instead of restarting (D8).
///
/// Detached bytes stay owned by the same [DownloadOutputOwner]; a manager
/// that cannot resume them still reaches the ordinary abort path.
abstract interface class ResumableDownloadSink implements DownloadSink {
  /// Bytes durably committed at the platform layer. Bytes still buffered in
  /// the coalescing writer do not count — this is the value a `Range` header
  /// may safely skip.
  int get storedBytes;

  /// Flushes, seals without finalizing, and returns the durable resume
  /// token. Afterwards the sink is dead: `write`/`finalize` throw and
  /// `abort()` is a no-op so manager cleanup can never delete preserved
  /// bytes. Returns null when this output cannot be preserved — the caller
  /// falls back to abort semantics.
  Future<ResumeAnchor?> detach();
}

/// Optional factory capability: reopen a previously detached output for
/// appending (D8). Legacy/unit factories remain valid without it.
abstract interface class ResumableDownloadSinkFactory {
  /// Reopens [anchor] under [owner] for appending. Returns null when the
  /// anchor is missing, foreign or unreadable — the caller discards the
  /// anchor and begins a fresh output. The returned sink must implement
  /// [ResumableDownloadSink] so the manager can verify the platform-side
  /// byte count against the durable record before trusting it.
  Future<DownloadSink?> resumeOwned(
    ResumeAnchor anchor,
    DownloadOutputOwner owner,
  );
}

/// Optional factory capability: non-download outputs (caption sidecars)
/// that materialize straight at the final display name — no `.part`
/// staging and no resume anchor.
abstract interface class RawDownloadSinkFactory {
  Future<DownloadSink> beginRaw({
    required String displayName,
    required String mimeType,
    required DownloadDestination destination,
    DownloadOutputOwner? owner,
  });
}

/// Minimum payload sent for a platform-channel download write.
const downloadChannelWriteSize = 256 * 1024;

class _CoalescingChannelWriter {
  _CoalescingChannelWriter(this._write);

  final Future<void> Function(List<int> bytes) _write;
  final BytesBuilder _pending = BytesBuilder(copy: false);
  var _pendingLength = 0;
  var _flushedLength = 0;

  /// Bytes the platform layer acknowledged. This is the only count a
  /// `Range` header may skip — buffered bytes are not yet durable.
  int get flushedBytes => _flushedLength;

  Future<void> write(List<int> bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      final capacity = downloadChannelWriteSize - _pendingLength;
      final remaining = bytes.length - offset;
      final count = remaining < capacity ? remaining : capacity;
      _pending.add(bytes.sublist(offset, offset + count));
      _pendingLength += count;
      offset += count;

      if (_pendingLength == downloadChannelWriteSize) {
        final chunk = _pending.takeBytes();
        _pendingLength = 0;
        await _write(chunk);
        _flushedLength += chunk.length;
      }
    }
  }

  Future<void> flush() async {
    if (_pendingLength == 0) return;
    final chunk = _pending.takeBytes();
    _pendingLength = 0;
    await _write(chunk);
    _flushedLength += chunk.length;
  }

  void discard() {
    _pending.takeBytes();
    _pendingLength = 0;
  }
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
        RecoverableDownloadSinkFactory,
        ResumableDownloadSinkFactory {
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

  /// Caption-sidecar entry point ([RawDownloadSinkFactory] via the routing
  /// factory): a pending row at the final name with no request context.
  Future<DownloadSink> beginRaw({
    required String displayName,
    required String mimeType,
    DownloadOutputOwner? owner,
    DownloadDestination destination = DownloadDestination.builtin,
  }) async {
    final relativePath = _relativePathFor(destination);
    final handle = owner != null && _session is OwnedMediaStoreSession
        ? await (_session as OwnedMediaStoreSession).beginOwned(
            displayName: displayName,
            mimeType: mimeType,
            owner: owner,
            relativePath: relativePath,
          )
        : await _session.begin(
            displayName: displayName,
            mimeType: mimeType,
            relativePath: relativePath,
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

  @override
  Future<DownloadSink?> resumeOwned(
    ResumeAnchor anchor,
    DownloadOutputOwner owner,
  ) async {
    final session = _session;
    ResumedPendingItem? resumed;
    if (anchor.kind == ResumeAnchorKind.mediaStore &&
        session is ResumableMediaStoreSession) {
      final id = int.tryParse(anchor.locator);
      resumed = id == null
          ? null
          : await (session as ResumableMediaStoreSession).resumePending(
              id,
              ownerId: owner.ownerId,
            );
    } else if (anchor.kind == ResumeAnchorKind.file &&
        session is ResumableFileMediaStoreSession) {
      resumed = await (session as ResumableFileMediaStoreSession)
          .resumePendingPath(anchor.locator);
    }
    if (resumed == null) return null;
    return _MediaStoreSink(resumed.handle, seededBytes: resumed.storedBytes);
  }
}

class _MediaStoreSink
    implements DownloadSink, DownloadSinkOutputMetadata, ResumableDownloadSink {
  _MediaStoreSink(MediaStoreHandle handle, {int seededBytes = 0})
    : _handle = handle,
      _seededBytes = seededBytes,
      _writer = _CoalescingChannelWriter(handle.write);

  final MediaStoreHandle _handle;

  /// Platform-reported durable bytes carried over from a resumed output.
  final int _seededBytes;
  final _CoalescingChannelWriter _writer;
  bool _finished = false;
  bool _finalizing = false;

  @override
  int? get pendingOutputId => _finished ? null : _handle.id;

  @override
  int get storedBytes => _seededBytes + _writer.flushedBytes;

  @override
  Future<void> write(List<int> bytes) {
    if (_finished) {
      throw StateError('sink already finalized or detached');
    }
    return _writer.write(bytes);
  }

  @override
  Future<ResumeAnchor?> detach() async {
    if (_finished) return null;
    final handle = _handle;
    if (handle is! ResumableMediaStoreHandle) return null;
    await _writer.flush();
    final locator = await handle.detach();
    _finished = true;
    return ResumeAnchor(
      kind: handle.anchorKind,
      locator: locator,
      storedBytes: storedBytes,
    );
  }

  @override
  Future<String> finalize() async {
    if (_finished || _finalizing) {
      throw StateError('sink already finalized or aborted');
    }
    _finalizing = true;
    try {
      await _writer.flush();
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
    _writer.discard();
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
    implements
        DownloadSinkFactory,
        OwnedDownloadSinkFactory,
        RawDownloadSinkFactory {
  final sinks = <MemorySink>[];

  /// Display names handed to [beginRaw], in order — caption tests assert
  /// the `<stem>.txt` name here.
  final rawNames = <String>[];

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

  @override
  Future<DownloadSink> beginRaw({
    required String displayName,
    required String mimeType,
    required DownloadDestination destination,
    DownloadOutputOwner? owner,
  }) async {
    rawNames.add(displayName);
    final sink = MemorySink();
    sinks.add(sink);
    return sink;
  }
}

/// SAF-backed sink writing into a persisted tree URI (D5). When [staged]
/// is set the document was created as `<name>.part` and commit renames it
/// to the final display name — the SAF equivalent of a MediaStore
/// pending row.
class SafDownloadSink implements DownloadSink, ResumableDownloadSink {
  SafDownloadSink(
    SafDocumentSink doc, {
    required this.owner,
    bool staged = false,
    int seededBytes = 0,
  }) : _doc = doc,
       _staged = staged,
       _seededBytes = seededBytes,
       _writer = _CoalescingChannelWriter(doc.write);

  final SafDocumentSink _doc;
  final _CoalescingChannelWriter _writer;
  final DownloadOutputOwner? owner;
  final bool _staged;
  final int _seededBytes;
  bool _closed = false;

  @override
  int get storedBytes => _seededBytes + _writer.flushedBytes;

  @override
  Future<void> write(List<int> bytes) {
    if (_closed) throw StateError('saf sink is closed');
    return _writer.write(bytes);
  }

  @override
  Future<ResumeAnchor?> detach() async {
    if (_closed) return null;
    final doc = _doc;
    if (doc is! ResumableSafDocument) return null;
    await _writer.flush();
    await doc.detachSaf();
    _closed = true;
    return ResumeAnchor(
      kind: ResumeAnchorKind.saf,
      locator: doc.resumeLocator,
      storedBytes: storedBytes,
    );
  }

  @override
  Future<String> finalize() async {
    if (_closed) throw StateError('saf sink is closed');
    await _writer.flush();
    if (_staged) {
      final doc = _doc;
      if (doc is! StagedSafDocument) {
        throw StateError('staged saf output cannot be renamed');
      }
      final uri = await doc.commitStaged();
      _closed = true;
      return uri;
    }
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
    _writer.discard();
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
    implements
        DownloadSinkFactory,
        OwnedDownloadSinkFactory,
        ResumableDownloadSinkFactory,
        RawDownloadSinkFactory {
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

  @override
  Future<DownloadSink> beginRaw({
    required String displayName,
    required String mimeType,
    required DownloadDestination destination,
    DownloadOutputOwner? owner,
  }) async {
    if (destination.isSafFolder) {
      // Caption sidecars are single small writes — straight to the final
      // name, no `.part` staging.
      final doc = await _saf.create(
        treeUri: destination.safTreeUri ?? '',
        displayName: displayName,
        mimeType: mimeType,
        owner: owner,
      );
      return SafDownloadSink(doc, owner: owner);
    }
    return _mediaStore.beginRaw(
      displayName: displayName,
      mimeType: mimeType,
      owner: owner,
      destination: destination,
    );
  }

  @override
  Future<DownloadSink?> resumeOwned(
    ResumeAnchor anchor,
    DownloadOutputOwner owner,
  ) {
    return switch (anchor.kind) {
      ResumeAnchorKind.saf => _resumeSaf(anchor, owner),
      _ => _mediaStore.resumeOwned(anchor, owner),
    };
  }

  Future<DownloadSink?> _resumeSaf(
    ResumeAnchor anchor,
    DownloadOutputOwner owner,
  ) async {
    final saf = _saf;
    if (saf is! ResumableSafDocumentFactory) return null;
    final resumed = await (saf as ResumableSafDocumentFactory).resumeSaf(
      uri: anchor.locator,
      owner: owner,
    );
    if (resumed == null) return null;
    return SafDownloadSink(
      resumed.sink,
      owner: owner,
      staged: true,
      seededBytes: resumed.storedBytes,
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
      staged: true,
    );
    return SafDownloadSink(doc, owner: owner, staged: true);
  }
}
