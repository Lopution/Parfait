import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../download/download_recovery.dart';
import 'desktop_file_sink.dart';
import 'platform_caps.dart';

/// Opens the platform directory chooser (ACTION_OPEN_DOCUMENT_TREE on
/// Android; `file_selector` on desktop) and returns the persisted tree
/// identifier — a `content://` tree URI on Android, a filesystem path on
/// desktop. No custom file browser, no raw path input: the platform owns
/// permission persistence.
abstract class SafTreePicker {
  /// Returns the tree identifier string, or null when the user cancelled.
  Future<String?> pickTree();
}

/// Streaming writer into a SAF tree document (D5). Writes go through the
/// platform channel; no full-file buffers on the Dart side.
abstract class SafDocumentSink {
  /// Opaque content URI returned by the platform document provider.
  String get uri;

  Future<void> write(List<int> bytes);
  Future<void> close();

  /// Closes and removes this document. Implementations must be idempotent.
  Future<void> delete();
}

/// Creates streaming sinks inside a persisted SAF tree.
abstract class SafDocumentSinkFactory {
  /// When [staged] is true the platform names the document `<name>.part`
  /// and the sink is expected to rename it to [displayName] on commit
  /// ([StagedSafDocument.commitStaged]) — the SAF equivalent of a
  /// MediaStore pending row.
  Future<SafDocumentSink> create({
    required String treeUri,
    required String displayName,
    required String mimeType,
    DownloadOutputOwner? owner,
    bool staged = false,
  });
}

/// Optional capability: the document was created staged (`.part`) and can
/// be atomically renamed to its final display name on commit.
abstract interface class StagedSafDocument implements SafDocumentSink {
  /// Closes and renames `<name>.part` → `<name>`; returns the final URI.
  /// A rename failure stays visible — the `.part` document is left for
  /// the caller's cleanup path.
  Future<String> commitStaged();
}

/// Optional capability: the platform can reopen this staged document for
/// appending via [ResumableSafDocumentFactory.resumeSaf] (D8).
abstract interface class ResumableSafDocument implements SafDocumentSink {
  /// Opaque locator a later `resumeSaf` call needs — the document URI on
  /// Android, the staged `.part` path on desktop.
  String get resumeLocator;

  /// Closes the write stream preserving the staged `.part` document.
  /// Distinct from [SafDocumentSink.close], which on some platforms
  /// commits the rename — detaching must never materialise the final
  /// name.
  Future<void> detachSaf();
}

/// Optional factory capability: reopen a detached staged document in
/// append mode ("wa"). Legacy factories remain valid without it.
abstract interface class ResumableSafDocumentFactory {
  /// Returns null when the document is missing or cannot be opened for
  /// appending — a safe refusal, never a delete.
  Future<({SafDocumentSink sink, int storedBytes})?> resumeSaf({
    required String uri,
    DownloadOutputOwner? owner,
  });
}

/// Production implementation backed by the Android host.
/// Native failures use `saf_<reason>` (`saf_invalid_argument`,
/// `saf_busy`, `saf_unavailable`, `saf_launch_failed`, `saf_permission`,
/// `saf_create_failed`, `saf_write_failed`, `saf_not_found`,
/// `saf_delete_failed`, `saf_io_failed`). [create] may send `ownerId`;
/// the Kotlin handler does not read it.
class MethodChannelSafTree
    implements
        SafTreePicker,
        SafDocumentSinkFactory,
        ResumableSafDocumentFactory {
  const MethodChannelSafTree([
    this._channel = const MethodChannel('pixivfunc/saf_tree'),
  ]);

  final MethodChannel _channel;

  @override
  Future<String?> pickTree() async {
    return await _channel.invokeMethod<String>('pickTree');
  }

  @override
  Future<SafDocumentSink> create({
    required String treeUri,
    required String displayName,
    required String mimeType,
    DownloadOutputOwner? owner,
    bool staged = false,
  }) async {
    final uri = await _channel.invokeMethod<String>('create', {
      'treeUri': treeUri,
      'displayName': displayName,
      'mimeType': mimeType,
      if (owner != null) 'ownerId': owner.ownerId,
      if (staged) 'staged': true,
    });
    if (uri == null) {
      throw const _SafTreeChannelException('create returned null uri');
    }
    return _MethodChannelSafDocumentSink(uri, _channel);
  }

  @override
  Future<({SafDocumentSink sink, int storedBytes})?> resumeSaf({
    required String uri,
    DownloadOutputOwner? owner,
  }) async {
    final Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMethod<Map<Object?, Object?>>('resume', {
        'uri': uri,
      });
    } on PlatformException {
      // Missing document or refused "wa" mode — a safe refusal, the
      // caller discards the anchor and begins fresh.
      return null;
    }
    if (raw == null) return null;
    final storedBytes = raw['storedBytes'];
    if (storedBytes is! int) {
      throw const _SafTreeChannelException('resume payload malformed');
    }
    return (
      sink: _MethodChannelSafDocumentSink(uri, _channel),
      storedBytes: storedBytes,
    );
  }
}

class _MethodChannelSafDocumentSink
    implements SafDocumentSink, StagedSafDocument, ResumableSafDocument {
  _MethodChannelSafDocumentSink(this._uri, this._channel);

  String _uri;
  final MethodChannel _channel;

  @override
  String get uri => _uri;

  @override
  String get resumeLocator => _uri;

  /// SAF detach is the plain stream close: the document keeps its
  /// `.part` name and committed bytes.
  @override
  Future<void> detachSaf() => close();

  @override
  Future<String> commitStaged() async {
    final renamed = await _channel.invokeMethod<String>('finalize', {
      'uri': _uri,
    });
    if (renamed == null || renamed.isEmpty) {
      throw const _SafTreeChannelException('finalize returned no uri');
    }
    _uri = renamed;
    return _uri;
  }

  @override
  Future<void> write(List<int> bytes) =>
      _channel.invokeMethod<void>('write', {'uri': _uri, 'bytes': bytes});

  @override
  Future<void> close() => _channel.invokeMethod<void>('close', {'uri': _uri});

  @override
  Future<void> delete() => _channel.invokeMethod<void>('delete', {'uri': _uri});
}

final safTreePickerProvider = Provider<SafTreePicker>((ref) {
  return ref.watch(platformCapsProvider).isAndroid
      ? const MethodChannelSafTree()
      : const DesktopDirectoryPicker();
});

final safDocumentSinkFactoryProvider = Provider<SafDocumentSinkFactory>((ref) {
  return ref.watch(platformCapsProvider).isAndroid
      ? const MethodChannelSafTree()
      : const DesktopSafDocumentSinkFactory();
});

class _SafTreeChannelException implements Exception {
  const _SafTreeChannelException(this.message);

  final String message;

  @override
  String toString() => 'SafTreeChannelException: $message';
}
