import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:parfait/core/image/image_worker_host.dart';
import 'package:parfait/core/image/image_worker_protocol.dart';
import 'package:parfait/core/image/lane_permit_gate.dart';
import 'package:parfait/core/network/compat/segmented_fetch.dart';
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

  Future<void> start({
    http.Client Function()? fetchClient,
    DateTime Function()? clock,
  }) async {
    dir = Directory.systemTemp.createTempSync('parfait-worker-');
    addTearDown(() => dir.delete(recursive: true));
    mainPort.listen((m) => _events.add(decodeWorkerEvent(m)));
    host = ImageWorkerHost(
      mainSendPort: mainPort.sendPort,
      config: testImageWorkerConfig,
      cacheDir: dir.path,
      transportInit: () async {},
      fetchClient: fetchClient,
      clock: clock,
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

  void watch(String url, {bool watching = true}) =>
      worker.send(encodeWatch(url, watching: watching));

  /// Every progress report received and not yet taken, oldest first.
  List<ProgressEvent> takeProgress() {
    final progress = _received.whereType<ProgressEvent>().toList();
    _received.removeWhere((e) => e is ProgressEvent);
    return progress;
  }

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

  test('progress goes out for watched URLs only, a tenth at a time', () async {
    // RangeServingClient answers in 64 KiB chunks: ten of them.
    const chunk = 64 * 1024;
    const size = 10 * chunk;
    const watched = 'https://i.pximg.net/img-master/watched.jpg';
    const unwatched = 'https://i.pximg.net/img-master/unwatched.jpg';
    const dropped = 'https://i.pximg.net/img-master/dropped.jpg';
    final client = RangeServingClient({
      for (final url in [watched, unwatched, dropped]) url: patternBytes(size),
    });
    // Every reading is a second on: the interval never holds a tenth back.
    var now = DateTime(2026, 10, 7);
    final harness = _Harness();
    addTearDown(harness.stop);
    await harness.start(
      fetchClient: () => client,
      clock: () => now = now.add(const Duration(seconds: 1)),
    );

    harness
      ..watch(watched)
      ..watch(dropped)
      ..watch(dropped, watching: false)
      ..fetch(1, watched)
      ..fetch(2, unwatched)
      ..fetch(3, dropped);
    for (final id in [1, 2, 3]) {
      expect(await harness.eventFor(id), isA<ResultEvent>());
    }
    final progress = harness.takeProgress();
    expect([for (final p in progress) p.url], everyElement(watched));
    expect(
      [for (final p in progress) p.received],
      [for (var i = 1; i <= 10; i++) i * chunk],
    );
    expect([for (final p in progress) p.total], everyElement(size));

    // A disk hit transfers nothing, so it reports nothing.
    harness.fetch(4, watched);
    expect(await harness.eventFor(4), isA<ResultEvent>());
    expect(harness.takeProgress(), isEmpty);
  });

  group('an original file', () {
    const original = 'https://i.pximg.net/img-original/big_p0.png';
    const segment = SegmentedFetch.defaultSegmentBytes;
    // Four segments, the last one short.
    const size = 3 * segment + 12345;

    Future<_Harness> started(RangeServingClient client) async {
      final harness = _Harness();
      addTearDown(harness.stop);
      await harness.start(fetchClient: () => client);
      return harness;
    }

    test('arrives whole from parallel ranges, its progress against the '
        'whole length', () async {
      final bytes = patternBytes(size);
      final client = RangeServingClient({original: bytes});
      final harness = await started(client);

      harness
        ..watch(original)
        ..fetch(1, original);
      final result = await harness.eventFor(1) as ResultEvent;
      expect(result.bytes, size);
      expect(await File(result.path).readAsBytes(), bytes);
      expect(client.ranges.first, 'bytes=0-${segment - 1}');
      expect(client.ranges, hasLength(4));
      expect(client.ranges, everyElement(isNotNull));
      // Every range is a pixiv image request, not only the first.
      expect(
        client.requests.map((r) => r.headers['referer']),
        everyElement(PixivHeaders.image()['Referer']),
      );
      final progress = harness.takeProgress();
      expect(progress, isNotEmpty);
      expect(progress.map((p) => p.total), everyElement(size));
      expect(progress.last.received, lessThanOrEqualTo(size));
    });

    test('a server that ignores Range sends the whole file at once', () async {
      final bytes = patternBytes(size);
      final client = RangeServingClient({original: bytes}, honorRange: false);
      final harness = await started(client);

      harness.fetch(1, original);
      final result = await harness.eventFor(1) as ResultEvent;
      expect(await File(result.path).readAsBytes(), bytes);
      expect(client.requests, hasLength(1));
    });

    test('a missing file fails with its status', () async {
      final harness = await started(RangeServingClient({}));

      harness.fetch(1, original);
      final failure = await harness.eventFor(1) as FailureEvent;
      expect(failure.statusCode, 404);
    });

    test('transfers share the worker\'s extra connections', () async {
      const other = 'https://i.pximg.net/img-original/other_p0.png';
      final client = RangeServingClient({
        original: patternBytes(size),
        other: patternBytes(size),
      }, hold: true);
      final harness = await started(client);

      harness
        ..fetch(1, original)
        ..fetch(2, other);
      // Each first range rides its lane permit; every further connection
      // comes from the worker's budget, whichever transfer takes it.
      const open = 2 + ImageWorkerHost.segmentLimit;
      await pollUntil(() => client.requests.length >= open);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(client.requests, hasLength(open));

      final results = Future.wait([harness.eventFor(1), harness.eventFor(2)]);
      var done = false;
      unawaited(results.whenComplete(() => done = true));
      while (!done) {
        client.releaseHeld();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await results, everyElement(isA<ResultEvent>()));
      expect(client.requests, hasLength(8));
    });
  });

  test('watch and progress messages survive the wire', () {
    for (final watching in [true, false]) {
      expect(
        decodeWorkerMessage(encodeWatch('u', watching: watching)),
        isA<WatchMessage>()
            .having((m) => m.url, 'url', 'u')
            .having((m) => m.watching, 'watching', watching),
      );
    }
    for (final total in [1000, null]) {
      expect(
        decodeWorkerEvent(encodeWorkerEvent(ProgressEvent('u', 10, total))),
        isA<ProgressEvent>()
            .having((e) => e.url, 'url', 'u')
            .having((e) => e.received, 'received', 10)
            .having((e) => e.total, 'total', total),
      );
    }
  });

  group('ImageProgressThrottle', () {
    late DateTime now;
    late ImageProgressThrottle throttle;
    setUp(() {
      now = DateTime(2026, 10, 7);
      throttle = ImageProgressThrottle(clock: () => now);
    });
    void wait(int ms) => now = now.add(Duration(milliseconds: ms));

    test('the first bytes report at once, short of a tenth', () {
      expect(throttle.shouldReport(1, 1000), isTrue);
    });

    test('a further report needs a new tenth and the interval', () {
      expect(throttle.shouldReport(50, 1000), isTrue);
      wait(500);
      expect(throttle.shouldReport(99, 1000), isFalse, reason: 'same tenth');
      expect(throttle.shouldReport(100, 1000), isTrue);
      wait(50);
      expect(throttle.shouldReport(250, 1000), isFalse, reason: 'too soon');
      wait(50);
      expect(throttle.shouldReport(260, 1000), isTrue);
    });

    test('a jump over several tenths reports once', () {
      expect(throttle.shouldReport(10, 1000), isTrue);
      wait(100);
      expect(throttle.shouldReport(900, 1000), isTrue);
      wait(100);
      expect(throttle.shouldReport(990, 1000), isFalse);
      expect(throttle.shouldReport(1000, 1000), isTrue);
    });

    test('without a total only the first bytes report', () {
      expect(throttle.shouldReport(10, null), isTrue);
      wait(1000);
      expect(throttle.shouldReport(1 << 20, null), isFalse);
    });
  });
}
