import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../download/download_custom_executor.dart';
import '../download/download_recovery.dart';
import '../download/download_request.dart';
import '../download/download_sink.dart';
import '../download/download_transport.dart';
import '../download/pixiv_download_transport.dart'
    show DownloadCancelledException;
import '../network/api_error.dart';
import '../network/pixiv_http_client.dart';
import 'ugoira_export.dart';
import 'ugoira_limits.dart';
import 'ugoira_repository.dart';

/// Single-permit FIFO mutex ensuring at most one GIF worker isolate encodes at
/// a time, even when multiple ugoira works are queued in [DownloadManager].
class _SingleGifEncodeLock {
  var _locked = false;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire(DownloadCancelToken cancelToken) async {
    if (cancelToken.isCancelled) throw const DownloadCancelledException();
    if (!_locked) {
      _locked = true;
      return;
    }
    final gate = Completer<void>();
    _waiters.addLast(gate);
    try {
      await Future.any<void>([
        gate.future,
        cancelToken.whenCancel.then<void>(
          (_) => throw const DownloadCancelledException(),
        ),
      ]);
    } catch (_) {
      if (gate.isCompleted) {
        release();
      } else {
        _waiters.remove(gate);
      }
      rethrow;
    }
  }

  void release() {
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      if (!next.isCompleted) {
        next.complete();
        return;
      }
    }
    _locked = false;
  }
}

/// Executes [DownloadTarget.ugoiraGif] jobs inside [DownloadManager] using
/// [UgoiraRepository] and [ImagePackageUgoiraGifEncoder] while capping active
/// GIF encoding isolates to one.
class UgoiraGifDownloadExecutor {
  UgoiraGifDownloadExecutor({
    required UgoiraRepository Function() readRepository,
    UgoiraGifEncoder Function(UgoiraLimits limits)? Function()?
    readEncoderFactory,
  }) : _readRepository = readRepository,
       _readEncoderFactory = readEncoderFactory;

  final UgoiraRepository Function() _readRepository;
  final UgoiraGifEncoder Function(UgoiraLimits limits)? Function()?
  _readEncoderFactory;
  final _SingleGifEncodeLock _encodeLock = _SingleGifEncodeLock();

  Future<void> execute({
    required DownloadRequest request,
    required DownloadSubmissionSnapshot snapshot,
    required DownloadSink sink,
    required DownloadCancelToken cancelToken,
    required void Function() checkOwner,
    required DownloadTargetProgressCallback onProgress,
  }) async {
    final loadCancel = CancelToken();
    unawaited(cancelToken.whenCancel.then((_) => loadCancel.cancel()));

    UgoiraAsset? asset;
    UgoiraGifEncoder? encoder;
    var lockHeld = false;
    try {
      checkOwner();
      if (cancelToken.isCancelled) throw const DownloadCancelledException();
      try {
        asset = await _readRepository().load(
          request.illustId,
          cancelToken: loadCancel,
        );
      } on ApiCancelled {
        throw const DownloadCancelledException();
      }
      checkOwner();
      if (cancelToken.isCancelled) throw const DownloadCancelledException();

      final totalFrames = asset.frameCount;
      onProgress(receivedBytes: 0, totalBytes: totalFrames);

      await _encodeLock.acquire(cancelToken);
      lockHeld = true;
      checkOwner();

      final customFactory = _readEncoderFactory?.call();
      encoder = customFactory != null
          ? customFactory(asset.limits)
          : ImagePackageUgoiraGifEncoder(limits: asset.limits);

      for (var index = 0; index < totalFrames; index++) {
        if (cancelToken.isCancelled) throw const DownloadCancelledException();
        checkOwner();
        final delay = Duration(
          milliseconds: asset.metadata.delayForIndex(index),
        );
        if (encoder is ImagePackageUgoiraGifEncoder) {
          final raw = await _awaitCancelable(
            asset.readFrameBytes(index),
            cancelToken,
          );
          final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
          await _awaitCancelable(
            encoder.addEncodedFrame(bytes, delay: delay),
            cancelToken,
          );
        } else {
          ui.Image? image;
          try {
            image = await asset.decodeFrame(index);
            await _awaitCancelable(
              encoder.addFrame(image, delay: delay),
              cancelToken,
            );
          } finally {
            image?.dispose();
          }
        }
        if (cancelToken.isCancelled) throw const DownloadCancelledException();
        onProgress(receivedBytes: index + 1, totalBytes: totalFrames);
        await Future<void>.delayed(Duration.zero);
      }

      final output = await _awaitCancelable(encoder.finish(), cancelToken);
      if (output.length > asset.limits.maxExportBytes) {
        throw const FormatException('GIF output exceeds limit');
      }
      final outputBytes = output is Uint8List
          ? output
          : Uint8List.fromList(output);
      for (var offset = 0; offset < outputBytes.length; offset += 64 * 1024) {
        if (cancelToken.isCancelled) throw const DownloadCancelledException();
        checkOwner();
        final end = (offset + 64 * 1024).clamp(0, outputBytes.length);
        await sink.write(Uint8List.sublistView(outputBytes, offset, end));
      }
      if (cancelToken.isCancelled) throw const DownloadCancelledException();
      checkOwner();
    } finally {
      await encoder?.dispose();
      if (lockHeld) _encodeLock.release();
      if (asset != null) await asset.dispose();
    }
  }

  static Future<T> _awaitCancelable<T>(
    Future<T> operation,
    DownloadCancelToken cancelToken,
  ) {
    if (cancelToken.isCancelled) {
      return Future<T>.error(const DownloadCancelledException());
    }
    return Future.any<T>([
      operation,
      cancelToken.whenCancel.then<T>(
        (_) => throw const DownloadCancelledException(),
      ),
    ]);
  }
}
