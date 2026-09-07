import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../download/download_recovery.dart';

/// Opens the Android system directory chooser (ACTION_OPEN_DOCUMENT_TREE)
/// and returns the persisted tree URI (D5). No custom file browser, no raw
/// path input: the platform owns permission persistence.
abstract class SafTreePicker {
  /// Returns the tree URI string, or null when the user cancelled.
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
  Future<SafDocumentSink> create({
    required String treeUri,
    required String displayName,
    required String mimeType,
    DownloadOutputOwner? owner,
  });
}

/// Production implementation backed by the Android host.
class MethodChannelSafTree implements SafTreePicker, SafDocumentSinkFactory {
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
  }) async {
    final uri = await _channel.invokeMethod<String>('create', {
      'treeUri': treeUri,
      'displayName': displayName,
      'mimeType': mimeType,
      if (owner != null) 'ownerId': owner.ownerId,
    });
    if (uri == null) {
      throw const SafTreeChannelException('create returned null uri');
    }
    return _MethodChannelSafDocumentSink(uri, _channel);
  }
}

class _MethodChannelSafDocumentSink implements SafDocumentSink {
  _MethodChannelSafDocumentSink(this._uri, this._channel);

  final String _uri;
  final MethodChannel _channel;

  @override
  String get uri => _uri;

  @override
  Future<void> write(List<int> bytes) => _channel.invokeMethod<void>(
    'write',
    {'uri': _uri, 'bytes': bytes},
  );

  @override
  Future<void> close() => _channel.invokeMethod<void>('close', {'uri': _uri});

  @override
  Future<void> delete() => _channel.invokeMethod<void>('delete', {'uri': _uri});
}

final safTreeProvider = Provider<MethodChannelSafTree>((ref) {
  return const MethodChannelSafTree();
});

final safTreePickerProvider = Provider<SafTreePicker>((ref) {
  return ref.watch(safTreeProvider);
});

final safDocumentSinkFactoryProvider = Provider<SafDocumentSinkFactory>((ref) {
  return ref.watch(safTreeProvider);
});

class SafTreeChannelException implements Exception {
  const SafTreeChannelException(this.message);

  final String message;

  @override
  String toString() => 'SafTreeChannelException: $message';
}
