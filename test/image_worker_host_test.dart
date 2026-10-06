import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:parfait/core/image/image_worker_host.dart';
import 'package:parfait/core/image/image_worker_protocol.dart';
import 'package:parfait/core/image/lane_permit_gate.dart';
import 'package:parfait/core/network/pixiv_headers.dart';

import 'helpers/image_network.dart';

/// A loopback image server: `/<name>` answers the PNG payload, `/hold/<x>`
/// keeps the response open until [release] is called.
class _Server {
  final hits = <String, int>{};
  final referers = <String>[];
  final _held = <HttpResponse>[];
  late final HttpServer inner;

  Future<void> start() async {
    inner = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      inner.forEach((request) async {
        final path = request.uri.path;
        hits[path] = (hits[path] ?? 0) + 1;
        referers.add(request.headers.value('referer') ?? '');
        if (path.startsWith('/hold/')) {
          _held.add(request.response);
          return;
        }
        request.response
          ..contentLength = onePixelPng.length
          ..add(onePixelPng);
        await request.response.close();
      }),
    );
  }

  String url(String path) => 'http://127.0.0.1:${inner.port}$path';

  void release() {
    for (final response in _held) {
      response
        ..contentLength = onePixelPng.length
        ..add(onePixelPng);
      unawaited(response.close());
    }
    _held.clear();
  }

  Future<void> stop() async {
    release();
    await inner.close(force: true);
  }
}

/// Drives an [ImageWorkerHost] in-process through its real wire protocol.
class _Harness {
  _Harness() {
    _events.stream.listen(_received.add);
  }

  late final ImageWorkerHost host;
  late final Directory dir;
  final mainPort = ReceivePort();
  final _events = StreamController<WorkerEvent>.broadcast();
  final _received = <WorkerEvent>[];
  late SendPort worker;
  _Server? server;

  Future<void> start({http.Client Function()? fetchClient}) async {
    dir = Directory.systemTemp.createTempSync('parfait-worker-');
    addTearDown(() => dir.delete(recursive: true));
    mainPort.listen((m) => _events.add(decodeWorkerEvent(m)));
    host = ImageWorkerHost(
      mainSendPort: mainPort.sendPort,
      config: testImageWorkerConfig,
      cacheDir: dir.path,
      transportInit: () async {},
      fetchClient: fetchClient,
    );
    unawaited(host.run());
    worker = await workerReady();
  }

  Future<SendPort> workerReady() async {
    while (true) {
      final event = await eventForAny();
      if (event is InitErrorEvent) {
        fail('worker init failed: ${event.message}');
      }
      if (event is ReadyEvent) return event.sendPort;
    }
  }

  Future<WorkerEvent> eventForAny({Duration? timeout}) {
    if (_received.isNotEmpty) {
      return Future.value(_received.removeAt(0));
    }
    return _events.stream.first
        .timeout(timeout ?? const Duration(seconds: 10))
        .then((e) {
          _received.remove(e);
          return e;
        });
  }

  void fetch(int id, String url, {ImageFetchPriority? priority}) {
    worker.send(
      encodeFetch(
        FetchRequest(id, url, priority ?? ImageFetchPriority.foreground),
      ),
    );
  }

  void cancel(int id) => worker.send(encodeCancel(id));

  bool _matches(WorkerEvent e, int id) =>
      (e is ResultEvent && e.id == id) || (e is FailureEvent && e.id == id);

  Future<WorkerEvent> eventFor(int id, {Duration? timeout}) {
    // The scan and the listen happen in one synchronous turn: an event
    // landing meanwhile is buffered in _received and also reaches the
    // broadcast listener, so nothing can be missed.
    for (var i = 0; i < _received.length; i++) {
      final e = _received[i];
      if (_matches(e, id)) {
        _received.removeAt(i);
        return Future.value(e);
      }
    }
    return _events.stream
        .where((e) => _matches(e, id))
        .first
        .timeout(timeout ?? const Duration(seconds: 10))
        .then((e) {
          _received.remove(e);
          return e;
        });
  }

  /// No event for [id] arrives during [during] — used to prove a cancelled
  /// request is silent.
  Future<void> expectSilent(int id, Duration during) async {
    try {
      await eventFor(id, timeout: during);
      fail('expected no event for $id');
    } on TimeoutException {
      // Silent window held — the cancelled request produced no event.
    }
  }

  Future<void> stop() async {
    await server?.stop();
    await host.close();
    mainPort.close();
    await _events.close();
  }
}

void main() {
  test('init failure reports initError instead of pretending ready', () async {
    final dir = Directory.systemTemp.createTempSync('parfait-worker-bad-');
    addTearDown(() => dir.delete(recursive: true));
    final mainPort = ReceivePort();
    // A file where a directory must be — the cache cannot open here.
    final blocker = File('${dir.path}/not-a-dir')..createSync();
    final host = ImageWorkerHost(
      mainSendPort: mainPort.sendPort,
      config: testImageWorkerConfig,
      cacheDir: blocker.path,
      transportInit: () async {},
      fetchClient: IOClient.new,
    );
    unawaited(host.run());
    final raw = await mainPort.first.timeout(const Duration(seconds: 10));
    expect(decodeWorkerEvent(raw), isA<InitErrorEvent>());
    mainPort.close();
  });

  test('a fetch streams the body to disk and replies with the path', () async {
    final harness = _Harness();
    addTearDown(harness.stop);
    final server = _Server();
    await server.start();
    harness.server = server;
    await harness.start(fetchClient: IOClient.new);

    final url = server.url('/img/one.jpg');
    harness.fetch(1, url);
    final event = await harness.eventFor(1);
    final result = event as ResultEvent;
    expect(result.id, 1);
    expect(result.bytes, onePixelPng.length);
    expect(await File(result.path).readAsBytes(), onePixelPng);
    // The pixiv CDN identity header is still sent.
    expect(server.referers.single, PixivHeaders.image()['Referer']);
  });

  test('a second fetch of the same URL is served from disk', () async {
    final harness = _Harness();
    addTearDown(harness.stop);
    final server = _Server();
    await server.start();
    harness.server = server;
    await harness.start(fetchClient: IOClient.new);

    final url = server.url('/img/two.jpg');
    harness.fetch(1, url);
    expect(await harness.eventFor(1), isA<ResultEvent>());
    harness.fetch(2, url);
    final second = await harness.eventFor(2) as ResultEvent;
    expect(await File(second.path).readAsBytes(), onePixelPng);
    expect(server.hits['/img/two.jpg'], 1);
  });

  test('a disk hit answers while every lane is busy', () async {
    final harness = _Harness();
    addTearDown(harness.stop);
    final server = _Server();
    await server.start();
    harness.server = server;
    await harness.start(fetchClient: IOClient.new);

    final url = server.url('/img/cached.jpg');
    harness.fetch(1, url);
    expect(await harness.eventFor(1), isA<ResultEvent>());
    for (var i = 0; i < 10; i++) {
      harness.fetch(100 + i, server.url('/hold/$i.jpg'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.hits.keys.where((p) => p.startsWith('/hold/')), hasLength(8));

    // The cached image must not queue behind the held transfers.
    harness.fetch(2, url);
    expect(
      await harness.eventFor(2, timeout: const Duration(seconds: 2)),
      isA<ResultEvent>(),
    );
    expect(server.hits['/img/cached.jpg'], 1);
  });

  test(
    'a malformed message is reported and the worker keeps serving',
    () async {
      final harness = _Harness();
      addTearDown(harness.stop);
      final server = _Server();
      await server.start();
      harness.server = server;
      await harness.start(fetchClient: IOClient.new);

      harness.worker.send(<String, Object?>{'type': 'bogus'});
      final error = await harness.eventForAny();
      expect(error, isA<WorkerErrorEvent>());
      expect((error as WorkerErrorEvent).message, contains('bogus'));

      harness.fetch(1, server.url('/img/after.jpg'));
      expect(await harness.eventFor(1), isA<ResultEvent>());
    },
  );

  test('a non-200 becomes a failure carrying the status code', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    unawaited(
      server.forEach((request) async {
        request.response.statusCode = 403;
        await request.response.close();
      }),
    );
    final harness = _Harness();
    addTearDown(harness.stop);
    await harness.start(fetchClient: IOClient.new);

    harness.fetch(1, 'http://127.0.0.1:${server.port}/forbidden.jpg');
    final event = await harness.eventFor(1);
    final failure = event as FailureEvent;
    expect(failure.statusCode, 403);
  });

  test('a cancelled queued fetch never reaches the network', () async {
    final harness = _Harness();
    addTearDown(harness.stop);
    final server = _Server();
    await server.start();
    harness.server = server;
    await harness.start(fetchClient: IOClient.new);

    // Occupy all eight foreground slots with held-open responses, then
    // queue a ninth and cancel it inside the grace window.
    for (var i = 0; i < 8; i++) {
      harness.fetch(100 + i, server.url('/hold/$i.jpg'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.hits.length, 8);
    harness.fetch(200, server.url('/img/queued.jpg'));
    harness.cancel(200);
    server.release();
    await harness.expectSilent(200, const Duration(milliseconds: 500));
    expect(server.hits.containsKey('/img/queued.jpg'), isFalse);
    for (var i = 0; i < 8; i++) {
      expect(await harness.eventFor(100 + i), isA<ResultEvent>());
    }
  });
}
