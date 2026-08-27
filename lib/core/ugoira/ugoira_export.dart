import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import '../download/download_request.dart';
import '../download/download_sink.dart';
import '../download/download_transport.dart';
import 'ugoira_limits.dart';
import 'ugoira_repository.dart';

enum UgoiraExportStatus { queued, running, succeeded, failed, canceled }

class UgoiraExportSnapshot {
  const UgoiraExportSnapshot({
    required this.status,
    required this.processedFrames,
    required this.totalFrames,
    this.uri,
    this.error,
  });

  const UgoiraExportSnapshot.queued(int totalFrames)
    : this(
        status: UgoiraExportStatus.queued,
        processedFrames: 0,
        totalFrames: totalFrames,
      );

  final UgoiraExportStatus status;
  final int processedFrames;
  final int totalFrames;
  final Uri? uri;
  final String? error;

  double get progress => totalFrames == 0 ? 0 : processedFrames / totalFrames;
}

/// Encoder boundary kept independent from the task lifecycle so tests can
/// verify cancellation/terminal semantics without creating native images.
abstract interface class UgoiraGifEncoder {
  Future<void> addFrame(ui.Image image, {required Duration delay});

  Future<List<int>> finish();

  Future<void> dispose();
}

/// Bounded, frame-at-a-time GIF encoder. Pixel extraction stays on the engine
/// boundary, while quantization and GIF assembly run in one cancellable worker
/// isolate. The worker retains at most the encoder's bounded output and its
/// current/previous frame, never the complete decoded-frame list.
class ImagePackageUgoiraGifEncoder implements UgoiraGifEncoder {
  ImagePackageUgoiraGifEncoder({required this.limits})
    : _worker = _UgoiraGifWorker(limits: limits);

  final UgoiraLimits limits;
  final _UgoiraGifWorker _worker;
  int? _width;
  int? _height;
  var _frameCount = 0;
  var _finished = false;

  @override
  Future<void> addFrame(ui.Image image, {required Duration delay}) async {
    if (_finished) throw StateError('GIF encoder is finished');
    if (image.width <= 0 || image.height <= 0) {
      throw const FormatException('GIF frame has invalid dimensions');
    }
    if (image.width > limits.maxFrameDimension ||
        image.height > limits.maxFrameDimension) {
      throw const FormatException('GIF frame dimensions exceed limit');
    }
    final width = _width;
    final height = _height;
    if (width != null && (width != image.width || height != image.height)) {
      throw const FormatException('GIF frames have inconsistent dimensions');
    }
    _width = image.width;
    _height = image.height;
    if (_frameCount >= limits.maxFrameCount) {
      throw const FormatException('GIF frame count exceeds limit');
    }
    if (image.width * image.height > limits.maxFramePixels ||
        image.width * image.height > limits.maxDecodedWindowBytes ~/ 4) {
      throw const FormatException('GIF frame pixels exceed limit');
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw const FormatException('frame pixels unavailable');
    final pixels = Uint8List.sublistView(
      data.buffer.asUint8List(),
      data.offsetInBytes,
      data.offsetInBytes + data.lengthInBytes,
    );
    await _worker.addFrame(
      width: image.width,
      height: image.height,
      pixels: pixels,
      delay: _centiseconds(delay),
    );
    _frameCount++;
  }

  @override
  Future<List<int>> finish() async {
    if (_finished) throw StateError('GIF encoder is finished');
    _finished = true;
    if (_frameCount == 0) {
      throw const FormatException('cannot export an empty GIF');
    }
    final bytes = await _worker.finish();
    if (bytes.length > limits.maxExportBytes) {
      throw const FormatException('GIF output exceeds limit');
    }
    return bytes;
  }

  @override
  Future<void> dispose() => _worker.dispose();

  static int _centiseconds(Duration delay) {
    final milliseconds = delay.inMilliseconds;
    return ((milliseconds + 5) ~/ 10).clamp(1, 65535);
  }
}

/// Owns one worker isolate for one export job. Sending pixels as transferable
/// data keeps the UI isolate responsive and prevents a second decoded-image
/// copy from being retained by the job.
class _UgoiraGifWorker {
  _UgoiraGifWorker({required this.limits}) {
    _responses.listen(_handleMessage);
    _errors.listen(_handleWorkerError);
    _exits.listen((_) => _handleWorkerExit());
    unawaited(_spawn());
  }

  final UgoiraLimits limits;
  final _responses = ReceivePort();
  final _errors = ReceivePort();
  final _exits = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<Object?>>{};
  Isolate? _isolate;
  var _nextId = 0;
  var _disposed = false;

  Future<void> _spawn() async {
    try {
      final isolate = await Isolate.spawn<List<Object>>(
        _ugoiraGifWorkerMain,
        <Object>[
          _responses.sendPort,
          limits.maxFrameCount,
          limits.maxFramePixels,
          limits.maxFrameDimension,
          limits.maxExportBytes,
        ],
        onError: _errors.sendPort,
        onExit: _exits.sendPort,
        errorsAreFatal: true,
      );
      if (_disposed) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
    } catch (error, stackTrace) {
      _fail(error, stackTrace);
    }
  }

  Future<void> addFrame({
    required int width,
    required int height,
    required Uint8List pixels,
    required int delay,
  }) async {
    if (pixels.length != width * height * 4) {
      throw const FormatException('GIF frame pixel buffer has invalid size');
    }
    await _request({
      'type': 'frame',
      'width': width,
      'height': height,
      'delay': delay,
      'pixels': TransferableTypedData.fromList([pixels]),
    });
  }

  Future<List<int>> finish() async {
    final result = await _request(const {'type': 'finish'});
    if (result is! Uint8List) {
      throw const FormatException('GIF worker returned no output');
    }
    return result;
  }

  Future<Object?> _request(Map<String, Object?> message) async {
    if (_disposed) throw StateError('GIF worker is disposed');
    final port = await _ready.future;
    if (_disposed) throw StateError('GIF worker is disposed');
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send({...message, 'id': id});
    return completer.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _responses.close();
    _errors.close();
    _exits.close();
    _isolate?.kill(priority: Isolate.immediate);
    _fail(StateError('GIF worker disposed'), StackTrace.current);
  }

  void _handleMessage(Object? message) {
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
      return;
    }
    if (message is! Map) return;
    final id = message['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (message['ok'] == true) {
      final rawBytes = message['bytes'];
      if (rawBytes is TransferableTypedData) {
        completer.complete(rawBytes.materialize().asUint8List());
      } else {
        completer.complete();
      }
    } else {
      completer.completeError(
        FormatException('${message['error'] ?? 'GIF worker failed'}'),
      );
    }
  }

  void _handleWorkerError(Object? message) {
    _fail(StateError('GIF worker failed: $message'), StackTrace.current);
  }

  void _handleWorkerExit() {
    if (_disposed) return;
    _fail(
      StateError('GIF worker exited unexpectedly'),
      StackTrace.current,
    );
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (!_ready.isCompleted) _ready.completeError(error, stackTrace);
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    _pending.clear();
  }
}

void _ugoiraGifWorkerMain(List<Object> args) {
  final parentPort = args[0] as SendPort;
  final maxFrameCount = args[1] as int;
  final maxFramePixels = args[2] as int;
  final maxFrameDimension = args[3] as int;
  final maxExportBytes = args[4] as int;
  final commands = ReceivePort();
  parentPort.send(commands.sendPort);
  var encoder = img.GifEncoder(
    numColors: 256,
    quantizerType: img.QuantizerType.neural,
  );
  var frameCount = 0;
  var finished = false;
  int? width;
  int? height;

  commands.listen((rawMessage) {
    if (rawMessage is! Map) return;
    final id = rawMessage['id'];
    if (id is! int) return;
    try {
      if (finished) throw StateError('GIF worker is finished');
      switch (rawMessage['type']) {
        case 'frame':
          final frameWidth = rawMessage['width'];
          final frameHeight = rawMessage['height'];
          final delay = rawMessage['delay'];
          final transfer = rawMessage['pixels'];
          if (frameWidth is! int ||
              frameHeight is! int ||
              delay is! int ||
              transfer is! TransferableTypedData) {
            throw const FormatException('GIF worker frame request malformed');
          }
          if (frameWidth <= 0 ||
              frameHeight <= 0 ||
              frameWidth > 65535 ||
              frameHeight > 65535 ||
              frameWidth > maxFrameDimension ||
              frameHeight > maxFrameDimension ||
              frameWidth * frameHeight > maxFramePixels) {
            throw const FormatException('GIF frame dimensions are invalid');
          }
          if (frameCount >= maxFrameCount) {
            throw const FormatException('GIF frame count exceeds limit');
          }
          if (width != null && (width != frameWidth || height != frameHeight)) {
            throw const FormatException(
              'GIF frames have inconsistent dimensions',
            );
          }
          final pixels = transfer.materialize().asUint8List();
          if (pixels.length != frameWidth * frameHeight * 4) {
            throw const FormatException(
              'GIF worker frame pixel buffer invalid',
            );
          }
          final frame = img.Image.fromBytes(
            width: frameWidth,
            height: frameHeight,
            bytes: pixels.buffer,
            numChannels: 4,
          );
          encoder.addFrame(frame, duration: delay);
          final encodedLength = encoder.output?.length;
          if (encodedLength != null && encodedLength > maxExportBytes) {
            throw const FormatException('GIF output exceeds limit');
          }
          width = frameWidth;
          height = frameHeight;
          frameCount++;
          break;
        case 'finish':
          if (frameCount == 0) {
            throw const FormatException('cannot export an empty GIF');
          }
          final bytes = encoder.finish();
          if (bytes == null) {
            throw const FormatException('GIF worker returned no output');
          }
          finished = true;
          parentPort.send({
            'id': id,
            'ok': true,
            'bytes': TransferableTypedData.fromList([bytes]),
          });
          return;
        default:
          throw const FormatException('GIF worker request unknown');
      }
      parentPort.send({'id': id, 'ok': true});
    } catch (error) {
      parentPort.send({'id': id, 'ok': false, 'error': error.toString()});
    }
  });
}

/// Post-process job for one Ugoira asset. It owns the pending output and emits
/// exactly one terminal status. Cancelling aborts only its own MediaStore
/// item; it never touches another download or job.
class UgoiraExportJob {
  UgoiraExportJob({
    required UgoiraAsset asset,
    required DownloadSinkFactory sinkFactory,
    UgoiraGifEncoder Function(UgoiraLimits limits)? encoderFactory,
  }) : _asset = asset,
       _sinkFactory = sinkFactory,
       _encoderFactory =
           encoderFactory ??
           ((limits) => ImagePackageUgoiraGifEncoder(limits: limits)),
       _snapshot = UgoiraExportSnapshot.queued(asset.frameCount);

  final UgoiraAsset _asset;
  final DownloadSinkFactory _sinkFactory;
  final UgoiraGifEncoder Function(UgoiraLimits limits) _encoderFactory;
  final _cancelToken = DownloadCancelToken();
  final _events = StreamController<UgoiraExportSnapshot>.broadcast();
  UgoiraExportSnapshot _snapshot;
  Future<UgoiraExportSnapshot>? _future;
  bool _terminal = false;

  UgoiraExportSnapshot get snapshot => _snapshot;

  Stream<UgoiraExportSnapshot> get events => _events.stream;

  Future<UgoiraExportSnapshot> start() => _future ??= _run();

  void cancel() {
    if (_terminal) return;
    _cancelToken.cancel();
  }

  Future<void> dispose() async {
    cancel();
    final future = _future;
    if (future != null) await future;
    await _events.close();
  }

  Future<UgoiraExportSnapshot> _run() async {
    DownloadSink? sink;
    UgoiraGifEncoder? encoder;
    try {
      _emit(
        UgoiraExportSnapshot(
          status: UgoiraExportStatus.running,
          processedFrames: 0,
          totalFrames: _asset.frameCount,
        ),
      );
      _checkCanceled();
      final request = DownloadRequest(
        illustId: _asset.illustId,
        pageIndex: 0,
        url: Uri.parse(
          'https://i.pximg.net/img-ugoira-export/${_asset.illustId}.gif',
        ),
        target: DownloadTarget.ugoiraGif,
      );
      sink = await _sinkFactory.begin(request, '${_asset.illustId}.gif');
      encoder = _encoderFactory(_asset.limits);
      for (var index = 0; index < _asset.frameCount; index++) {
        _checkCanceled();
        ui.Image? image;
        try {
          image = await _asset.decodeFrame(index);
          await _awaitCancelable(
            encoder.addFrame(
              image,
              delay: Duration(
                milliseconds: _asset.metadata.delayForIndex(index),
              ),
            ),
          );
        } finally {
          image?.dispose();
        }
        _checkCanceled();
        _emit(
          UgoiraExportSnapshot(
            status: UgoiraExportStatus.running,
            processedFrames: index + 1,
            totalFrames: _asset.frameCount,
          ),
        );
        await Future<void>.delayed(Duration.zero);
      }
      final output = await _awaitCancelable(encoder.finish());
      if (output.length > _asset.limits.maxExportBytes) {
        throw const FormatException('GIF output exceeds limit');
      }
      for (var offset = 0; offset < output.length; offset += 64 * 1024) {
        _checkCanceled();
        final end = (offset + 64 * 1024).clamp(0, output.length);
        await sink.write(output.sublist(offset, end));
      }
      _checkCanceled();
      final uri = Uri.parse(await sink.finalize());
      _emitTerminal(
        UgoiraExportSnapshot(
          status: UgoiraExportStatus.succeeded,
          processedFrames: _asset.frameCount,
          totalFrames: _asset.frameCount,
          uri: uri,
        ),
      );
    } on UgoiraExportCanceledException {
      await encoder?.dispose();
      await _abort(sink);
      _emitTerminal(
        UgoiraExportSnapshot(
          status: UgoiraExportStatus.canceled,
          processedFrames: _snapshot.processedFrames,
          totalFrames: _asset.frameCount,
        ),
      );
    } catch (error) {
      await encoder?.dispose();
      await _abort(sink);
      _emitTerminal(
        UgoiraExportSnapshot(
          status: UgoiraExportStatus.failed,
          processedFrames: _snapshot.processedFrames,
          totalFrames: _asset.frameCount,
          error: error.toString(),
        ),
      );
    }
    await encoder?.dispose();
    return _snapshot;
  }

  Future<T> _awaitCancelable<T>(Future<T> operation) {
    return Future.any<T>([
      operation,
      _cancelToken.whenCancel.then<T>(
        (_) => throw const UgoiraExportCanceledException(),
      ),
    ]);
  }

  void _checkCanceled() {
    if (_cancelToken.isCancelled) throw const UgoiraExportCanceledException();
  }

  Future<void> _abort(DownloadSink? sink) async {
    if (sink == null) return;
    try {
      await sink.abort();
    } catch (_) {
      // Sink cleanup is isolated from the terminal failure. The sink contract
      // and platform bridge own their own pending-row recovery.
    }
  }

  void _emit(UgoiraExportSnapshot value) {
    if (_terminal) return;
    _snapshot = value;
    if (!_events.isClosed) _events.add(value);
  }

  void _emitTerminal(UgoiraExportSnapshot value) {
    if (_terminal) return;
    _snapshot = value;
    _terminal = true;
    if (!_events.isClosed) _events.add(value);
  }
}

class UgoiraExportCanceledException implements Exception {
  const UgoiraExportCanceledException();
}
