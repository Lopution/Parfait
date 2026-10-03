import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_request.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/download/download_transport.dart';
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/download/pixiv_download_transport.dart'
    show DownloadCancelledException;

import 'test_preferences.dart';

/// Scripted transport: each open() pops the next [ScriptedResponse].
class FakeTransport implements DownloadTransport {
  final responses = <ScriptedResponse>[];
  final openedUrls = <Uri>[];
  final activeResponses = <_FakeResponse>[];

  @override
  Future<DownloadResponse> open(
    Uri url, {
    required Map<String, String> headers,
    required DownloadCancelToken cancelToken,
  }) async {
    openedUrls.add(url);
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
    if (script.error != null) {
      return Stream<List<int>>.error(script.error!);
    }
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
  final container = ProviderContainer(
    overrides: [downloadManagerProvider.overrideWithValue(manager)],
  );
  addTearDown(container.dispose);
  return (container, manager, transport);
}

/// Pumps 20ms frames until [predicate] holds or [tries] run out.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  int tries = 40,
}) async {
  for (var i = 0; i < tries && !predicate(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
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
