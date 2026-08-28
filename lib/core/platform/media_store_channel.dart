import 'package:flutter/services.dart';

import 'android_platform_interfaces.dart';
import '../download/download_recovery.dart';

/// MethodChannel contract for MediaStore pending writes
/// (Pictures/PixivFunc). See
/// .trellis/tasks/08-26-download-manager-mediastore/research/download-pipeline.md
/// for the API-level behavior matrix.
abstract final class MediaStoreMethods {
  static const channel = 'pixivfunc/mediastore';
  static const begin = 'begin';
  static const write = 'write';
  static const finalize = 'finalize';
  static const abort = 'abort';
  static const listPending = 'listPending';
  static const abortPending = 'abortPending';
}

/// Production [MediaStoreSession] backed by the Android host
/// (MainActivity.kt). Fails fast (`unsupported`) below API 29 where scoped
/// MediaStore does not exist; the download pipeline surfaces that as a
/// failed task instead of silently degrading.
class MethodChannelMediaStoreSession
    implements
        MediaStoreSession,
        OwnedMediaStoreSession,
        RecoverableMediaStoreSession {
  const MethodChannelMediaStoreSession([
    this._channel = const MethodChannel(MediaStoreMethods.channel),
  ]);

  final MethodChannel _channel;

  @override
  Future<MediaStoreHandle> begin({
    required String displayName,
    required String mimeType,
  }) async {
    final id = await _channel.invokeMethod<int>(MediaStoreMethods.begin, {
      'displayName': displayName,
      'mimeType': mimeType,
    });
    if (id == null) {
      throw const MediaStoreChannelException('begin returned null id');
    }
    return _MethodChannelMediaStoreHandle(id, _channel);
  }

  @override
  Future<MediaStoreHandle> beginOwned({
    required String displayName,
    required String mimeType,
    required DownloadOutputOwner owner,
  }) async {
    final id = await _channel.invokeMethod<int>(MediaStoreMethods.begin, {
      'displayName': displayName,
      'mimeType': mimeType,
      'ownerId': owner.ownerId,
    });
    if (id == null) {
      throw const MediaStoreChannelException('begin returned null id');
    }
    return _MethodChannelMediaStoreHandle(id, _channel);
  }

  @override
  Future<List<PendingMediaStoreItem>> listPending() async {
    final raw = await _channel.invokeMethod<List<Object?>>(
      MediaStoreMethods.listPending,
    );
    if (raw == null) return const [];
    final pending = <PendingMediaStoreItem>[];
    for (final value in raw) {
      if (value is! Map) {
        throw const MediaStoreChannelException('pending item is malformed');
      }
      final map = value.cast<Object?, Object?>();
      final id = map['id'];
      final displayName = map['displayName'];
      final ownerId = map['ownerId'];
      if (id is! int ||
          displayName is! String ||
          (ownerId != null && ownerId is! String)) {
        throw const MediaStoreChannelException('pending item fields malformed');
      }
      pending.add(
        PendingMediaStoreItem(
          id: id,
          displayName: displayName,
          ownerId: ownerId as String?,
        ),
      );
    }
    return pending;
  }

  @override
  Future<bool> abortPending(int id, {required String ownerId}) async {
    return await _channel.invokeMethod<bool>(MediaStoreMethods.abortPending, {
          'id': id,
          'ownerId': ownerId,
        }) ??
        false;
  }
}

class _MethodChannelMediaStoreHandle implements MediaStoreHandle {
  _MethodChannelMediaStoreHandle(this.id, this._channel);

  @override
  final int id;

  final MethodChannel _channel;

  @override
  Future<void> write(List<int> bytes) => _channel.invokeMethod<void>(
    MediaStoreMethods.write,
    {'id': id, 'bytes': bytes},
  );

  @override
  Future<Uri> finalize() async {
    final uri = await _channel.invokeMethod<String>(
      MediaStoreMethods.finalize,
      {'id': id},
    );
    if (uri == null || uri.isEmpty) {
      throw const MediaStoreChannelException('finalize returned no uri');
    }
    return Uri.parse(uri);
  }

  @override
  Future<void> abort() async {
    try {
      await _channel.invokeMethod<void>(MediaStoreMethods.abort, {'id': id});
    } on PlatformException {
      // Cleanup must not mask the original failure (R6); pending rows for
      // dead processes are cleared by the OS itself.
    }
  }
}

class MediaStoreChannelException implements Exception {
  const MediaStoreChannelException(this.message);

  final String message;

  @override
  String toString() => 'MediaStoreChannelException: $message';
}
