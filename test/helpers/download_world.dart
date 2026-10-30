import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parfait/core/download/download_destination.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_request.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/download/download_transport.dart';
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/download/pixiv_download_transport.dart'
    show DownloadCancelledException, RawHop;

import 'test_preferences.dart';

/// Scripted transport: each open() pops the next [ScriptedResponse].
class FakeTransport implements DownloadTransport {
  final responses = <ScriptedResponse>[];
  final openedUrls = <Uri>[];
  final openedHeaders = <Map<String, String>>[];
  final activeResponses = <_FakeResponse>[];

  @override
  Future<DownloadResponse> open(
    Uri url, {
    required Map<String, String> headers,
    required DownloadCancelToken cancelToken,
  }) async {
    openedUrls.add(url);
    openedHeaders.add(Map.of(headers));
    final response = _FakeResponse(responses.removeAt(0), cancelToken);
    activeResponses.add(response);
    return response;
  }
}

class ScriptedResponse {
  ScriptedResponse({
    this.statusCode = 200,
    this.contentLength,
    this.chunks = const [],
    this.completers,
    this.error,
  });

  final int statusCode;
  final int? contentLength;
  final List<List<int>> chunks;

  /// When non-null, chunk [i] is gated behind completers[i]; the stream
  /// only completes when tests flush it.
  final List<Completer<void>>? completers;

  /// Raised after [chunks], as a connection dropped mid-body.
  final Object? error;
}

class _FakeResponse implements DownloadResponse {
  _FakeResponse(this.script, this.cancelToken);

  final ScriptedResponse script;
  final DownloadCancelToken cancelToken;
  final _closed = Completer<void>();

  @override
  int get statusCode => script.statusCode;

  @override
  int? get contentLength => script.contentLength;

  @override
  Stream<List<int>> get stream {
    final completers = script.completers;
    var index = 0;
    final controller = StreamController<List<int>>();
    Future<void> drain() async {
      try {
        for (final chunk in script.chunks) {
          if (cancelToken.isCancelled) {
            await close();
            controller.addError(const DownloadCancelledException());
            return;
          }
          final gate = completers == null ? null : completers[index++];
          if (gate != null) {
            await gate.future;
          }
          if (cancelToken.isCancelled) {
            await close();
            controller.addError(const DownloadCancelledException());
            return;
          }
          controller.add(chunk);
          // Yield so the consumer's await for actually progresses.
          await Future<void>.delayed(Duration.zero);
        }
        if (script.error case final error?) controller.addError(error);
        await controller.close();
      } catch (error) {
        controller.addError(error);
        await controller.close();
      }
    }

    unawaited(drain());
    return controller.stream;
  }

  @override
  Future<void> close() {
    if (!_closed.isCompleted) {
      _closed.complete();
    }
    return _closed.future;
  }
}

/// A real [DownloadManager] over [responses] and memory sinks.
Future<(ProviderContainer, DownloadManager, FakeTransport)> makeDownloadWorld({
  required List<ScriptedResponse> responses,
  int maxConcurrent = 3,
}) async {
  installMemoryPreferences();
  final transport = FakeTransport()..responses.addAll(responses);
  final manager = DownloadManager(
    transport: transport,
    sinkFactory: MemorySinkFactory(),
    maxConcurrent: maxConcurrent,
  );
  final container = ProviderContainer.test(
    overrides: [downloadManagerProvider.overrideWithValue(manager)],
  );
  return (container, manager, transport);
}

DownloadRequest downloadRequest(
  int id, {
  String? title,
  String? artist,
  int pageIndex = 0,
  int? totalPages,
  String? thumbnailUrl,
  NamingRule? namingRule,
}) => DownloadRequest(
  illustId: id,
  pageIndex: pageIndex,
  url: Uri.parse('https://i.pximg.net/$id/p$pageIndex.jpg'),
  target: DownloadTarget.illustPage,
  title: title,
  artist: artist,
  totalPages: totalPages,
  thumbnailUrl: thumbnailUrl,
  namingRule: namingRule,
);

ScriptedResponse gatedResponse(Completer<void> gate, {int byte = 1}) =>
    ScriptedResponse(
      contentLength: 1,
      chunks: [
        [byte],
      ],
      completers: [gate],
    );

/// A raw redirect hop with a scripted status, location and body; each
/// body chunk can wait on its gate.
class ScriptedHop implements RawHop {
  ScriptedHop({
    required this.statusCode,
    String? location,
    this.contentLength,
    List<List<int>> bodyChunks = const [],
    this.gates,
  }) : _location = location,
       _bodyChunks = bodyChunks;

  @override
  final int statusCode;
  final String? _location;
  @override
  final int? contentLength;
  final List<List<int>> _bodyChunks;
  final List<Completer<void>>? gates;

  var aborted = false;
  var _listened = false;

  @override
  String? get locationHeader => _location;

  @override
  Stream<List<int>> get body {
    if (_listened) {
      throw StateError('hop body already consumed');
    }
    _listened = true;
    final gates = this.gates;
    late StreamController<List<int>> controller;
    Future<void> pump() async {
      for (var i = 0; i < _bodyChunks.length; i++) {
        final gate = gates == null ? null : gates[i];
        if (gate != null) {
          await gate.future;
        }
        controller.add(_bodyChunks[i]);
        await Future<void>.delayed(Duration.zero);
      }
      await controller.close();
    }

    controller = StreamController<List<int>>(
      onListen: () {
        unawaited(pump());
      },
    );
    return controller.stream;
  }

  @override
  Future<void> drain() async {}

  @override
  void abort() => aborted = true;
}

/// A sink that keeps the first chunk, then fails the write with [error]:
/// a disk that fills up, or a destination that goes away, mid-file.
class ThrowAfterWriteSinkFactory implements DownloadSinkFactory {
  ThrowAfterWriteSinkFactory([this.error]);

  final Object? error;
  MemorySink? lastSink;

  @override
  Future<DownloadSink> begin(
    DownloadRequest request,
    String displayName, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) async {
    final inner = MemorySink();
    lastSink = inner;
    return _ThrowAfterWriteSink(inner, error);
  }
}

class _ThrowAfterWriteSink implements DownloadSink {
  _ThrowAfterWriteSink(this.inner, this.error);

  final MemorySink inner;
  final Object? error;

  @override
  Future<void> write(List<int> bytes) async {
    await inner.write(bytes);
    throw error ?? Exception('sink write exploded');
  }

  @override
  Future<String> finalize() => inner.finalize();

  @override
  Future<void> abort() => inner.abort();
}
