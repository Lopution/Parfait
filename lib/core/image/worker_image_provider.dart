import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'image_worker_protocol.dart';
import 'lane_permit_gate.dart';

/// An [ImageProvider] whose bytes come from the background image worker:
/// it resolves the worker's committed file path and hands it to the engine
/// via `ImmutableBuffer.fromFilePath`, so Dart never touches image bytes
/// and decode stays exactly where `FileImage` puts it.
///
/// The cache key is [url] alone, priority outside it: a background
/// preload and the visible resolve share one pending stream, and priority
/// changes are scheduling events (the demand `hold` → `promoteUrl`
/// signal), not new identities.
class WorkerImageProvider extends ImageProvider<WorkerImageProvider> {
  WorkerImageProvider(
    this.worker,
    this.url, {
    this.priority = ImageFetchPriority.foreground,
  });

  final ImageFetcher worker;
  final String url;

  /// The lane this resolve prefers; not part of the key. When a
  /// lower-priority stream is already pending, the visible holder promotes
  /// the worker fetch instead of starting a second stream.
  final ImageFetchPriority priority;

  @override
  Future<WorkerImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(
    WorkerImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(decode),
      scale: 1.0,
      debugLabel: url,
      informationCollector: () => [
        DiagnosticsProperty<String>('URL', url),
        DiagnosticsProperty<String>('priority', priority.name),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(ImageDecoderCallback decode) async {
    final result = await worker.fetch(url, priority: priority);
    // The file may be evicted between the worker's commit and this read —
    // a rare LRU race; it surfaces as an ordinary image error, which the
    // widget layer retries through the same path as a failed fetch.
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(result.file.path);
      return _DiscardOnFailure(await decode(buffer), _discard);
    } on Object {
      _discard();
      rethrow;
    }
  }

  /// Bytes that do not decode (a 200 carrying an error page, a body cut
  /// short) would answer that retry from the disk cache forever.
  void _discard() => worker.discard(url);

  @override
  bool operator ==(Object other) =>
      other is WorkerImageProvider && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'WorkerImageProvider("$url")';
}

/// [_codec], calling [_onFailure] when a frame fails to decode: a file
/// whose header parses but whose pixels are broken fails only there.
class _DiscardOnFailure implements ui.Codec {
  _DiscardOnFailure(this._codec, this._onFailure);

  final ui.Codec _codec;
  final VoidCallback _onFailure;

  @override
  int get frameCount => _codec.frameCount;

  @override
  int get repetitionCount => _codec.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    try {
      return await _codec.getNextFrame();
    } on Object {
      _onFailure();
      rethrow;
    }
  }

  @override
  void dispose() => _codec.dispose();
}
