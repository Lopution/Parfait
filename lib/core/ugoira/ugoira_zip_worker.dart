import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

import 'ugoira_zip.dart';

/// Persistent, cancellable Dart worker isolate that reads, bounds-inflates,
/// and CRC32-verifies ZIP entries off the Flutter UI isolate, returning frame
/// bytes via [TransferableTypedData] without extra copies.
class UgoiraZipWorker {
  UgoiraZipWorker(this.path) {
    _responses.listen(_handleMessage);
    _errors.listen(_handleError);
    _exits.listen((_) => _handleExit());
    unawaited(_spawn());
  }

  final String path;
  final _responses = ReceivePort();
  final _errors = ReceivePort();
  final _exits = ReceivePort();
  final _ready = Completer<SendPort>();
  SendPort? _port;
  final _pending = <int, Completer<Uint8List>>{};
  Isolate? _isolate;
  var _nextId = 0;
  var _disposed = false;

  Future<void> _spawn() async {
    try {
      final isolate = await Isolate.spawn<List<Object>>(
        _ugoiraZipWorkerMain,
        <Object>[_responses.sendPort, path],
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

  Future<Uint8List> readEntry(UgoiraZipEntry entry) async {
    if (_disposed) throw StateError('ugoira archive is disposed');
    final port = await _ready.future;
    if (_disposed) throw StateError('ugoira archive is disposed');
    final id = _nextId++;
    final completer = Completer<Uint8List>();
    _pending[id] = completer;
    port.send(<Object>[
      id,
      entry.dataOffset,
      entry.compressedSize,
      entry.uncompressedSize,
      entry.compressionMethod,
      entry.crc32,
    ]);
    return completer.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _port?.send(null);
    _port = null;
    _responses.close();
    _errors.close();
    _exits.close();
    _isolate?.kill(priority: Isolate.immediate);
    _fail(StateError('ugoira archive is disposed'), StackTrace.current);
  }

  void _handleMessage(Object? message) {
    if (message is SendPort) {
      _port = message;
      if (!_ready.isCompleted) _ready.complete(message);
      return;
    }
    if (message is! List || message.length < 2) return;
    final id = message[0];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    final ok = message[1] == true;
    if (ok && message.length >= 3 && message[2] is TransferableTypedData) {
      final bytes = (message[2] as TransferableTypedData)
          .materialize()
          .asUint8List();
      completer.complete(bytes);
    } else {
      final err = message.length >= 3 ? '${message[2]}' : 'archive read failed';
      completer.completeError(UgoiraArchiveException(err));
    }
  }

  void _handleError(Object? message) {
    _fail(
      UgoiraArchiveException('archive worker failed: $message'),
      StackTrace.current,
    );
  }

  void _handleExit() {
    if (_disposed) return;
    _fail(
      const UgoiraArchiveException('archive worker exited unexpectedly'),
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

void _ugoiraZipWorkerMain(List<Object> args) {
  final parentPort = args[0] as SendPort;
  final path = args[1] as String;
  final commands = ReceivePort();
  parentPort.send(commands.sendPort);

  RandomAccessFile? raf;
  commands.listen((raw) {
    if (raw == null) {
      try {
        raf?.closeSync();
      } on Object {
        // Best-effort close on worker shutdown.
      }
      raf = null;
      commands.close();
      return;
    }
    if (raw is! List || raw.length < 6) return;
    final id = raw[0] as int;
    final dataOffset = raw[1] as int;
    final compressedSize = raw[2] as int;
    final uncompressedSize = raw[3] as int;
    final method = raw[4] as int;
    final expectedCrc = raw[5] as int;
    try {
      final file = raf ??= File(path).openSync();
      file.setPositionSync(dataOffset);
      final compressed = file.readSync(compressedSize);
      if (compressed.length != compressedSize) {
        throw const UgoiraArchiveException('archive read was truncated');
      }
      final Uint8List decoded;
      switch (method) {
        case 0:
          decoded = compressed;
        case 8:
          decoded = SafeZipIndex.inflateCapped(compressed, uncompressedSize);
        default:
          throw const UgoiraArchiveException('compression method rejected');
      }
      if (decoded.length != uncompressedSize) {
        throw const UgoiraArchiveException(
          'entry size does not match metadata',
        );
      }
      if (getCrc32(decoded) != expectedCrc) {
        throw const UgoiraArchiveException('entry CRC mismatch');
      }
      parentPort.send(<Object>[
        id,
        true,
        TransferableTypedData.fromList([decoded]),
      ]);
    } on UgoiraArchiveException catch (error) {
      parentPort.send(<Object>[id, false, error.message]);
    } catch (error) {
      parentPort.send(<Object>[
        id,
        false,
        'frame decompression failed: $error',
      ]);
    }
  });
}
