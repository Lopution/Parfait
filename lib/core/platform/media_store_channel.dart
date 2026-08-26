import 'package:flutter/services.dart';

import 'android_platform_interfaces.dart';

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
}

/// Production [MediaStoreSession] backed by the Android host
/// (MainActivity.kt). Fails fast (`unsupported`) below API 29 where scoped
/// MediaStore does not exist; the download pipeline surfaces that as a
/// failed task instead of silently degrading.
class MethodChannelMediaStoreSession implements MediaStoreSession {
  const MethodChannelMediaStoreSession([this._channel = const MethodChannel(
    MediaStoreMethods.channel,
  )]);

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
}

class _MethodChannelMediaStoreHandle implements MediaStoreHandle {
  _MethodChannelMediaStoreHandle(this.id, this._channel);

  @override
  final int id;

  final MethodChannel _channel;

  @override
  Future<void> write(List<int> bytes) => _channel
      .invokeMethod<void>(MediaStoreMethods.write, {'id': id, 'bytes': bytes});

  @override
  Future<Uri> finalize() async {
    final uri = await _channel
        .invokeMethod<String>(MediaStoreMethods.finalize, {'id': id});
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
