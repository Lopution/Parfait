@Tags(['socket'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:parfait/core/image/image_worker_host.dart';
import 'package:parfait/core/image/image_worker_protocol.dart';
import 'package:parfait/core/image/lane_permit_gate.dart';
import 'package:parfait/core/network/compat/image_route_scores.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart';
import 'package:parfait/core/network/pixiv_headers.dart';

import 'helpers/image_network.dart';
import 'helpers/waits.dart';

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
  PngServer? server;

  Future<void> start({
    ImageWorkerConfig config = testImageWorkerConfig,
    http.Client Function()? fetchClient,
    NetworkClientFactory? clientFactory,
    DateTime Function()? clock,
  }) async {
    dir = Directory.systemTemp.createTempSync('parfait-worker-');
    addTearDown(() => dir.delete(recursive: true));
    mainPort.listen((m) => _events.add(decodeWorkerEvent(m)));
    host = ImageWorkerHost(
      mainSendPort: mainPort.sendPort,
      config: config,
      cacheDir: dir.path,
      transportInit: () async {},
      fetchClient: fetchClient,
      clientFactory: clientFactory,
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

  void lookup(int id, String url) => worker.send(encodeLookup(id, url));

  bool _matches(WorkerEvent e, int id) => switch (e) {
    ResultEvent() => e.id == id,
    FailureEvent() => e.id == id,
    CachedEvent() => e.id == id,
    RoutesEvent() => e.id == id,
    _ => false,
  };

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

/// [testImageWorkerConfig] on another network.
const _otherNetwork = ImageWorkerConfig(
  imageSource: 'i.pximg.net',
  mode: 'directOnly',
  networkIdentity: 'other-net',
  echFrontHost: 'cloudflare-ech.com',
  dohEndpoints: [],
  bootstrapNoSniEnabled: true,
);

/// [testImageWorkerConfig] with pixiv's image routes on [network]: the
/// origin only, as no ECH config is to be had.
ImageWorkerConfig _routedOn(
  String network, {
  Map<String, ImageRouteScore> scores = const {},
}) => ImageWorkerConfig(
  imageSource: 'i.pximg.net',
  mode: 'automatic',
  networkIdentity: network,
  echFrontHost: 'cloudflare-ech.com',
  dohEndpoints: const [],
  bootstrapNoSniEnabled: true,
  routeScores: scores,
);

/// Answers every image GET with one byte, keeping the requests.
class _RecordingImageClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(Stream.value([1]), 200, request: request);
  }
}

/// Its first answer's body breaks on [breakFirst], as when the route pool
/// under it closes; every later request gets the image.
class _FirstBodyBreaksClient extends http.BaseClient {
  final _firstBody = StreamController<List<int>>();
  var requests = 0;

  void breakFirst() {
    _firstBody.addError(http.ClientException('connection closed'));
    unawaited(_firstBody.close());
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    return http.StreamedResponse(
      requests == 1 ? _firstBody.stream : Stream.value(onePixelPng),
      200,
      request: request,
    );
  }
}

/// A started harness whose worker fetches from a live local [PngServer].
Future<_Harness> _served() async {
  final harness = _Harness();
  addTearDown(harness.stop);
  final server = PngServer(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );
  harness.server = server;
  await harness.start(fetchClient: IOClient.new);
  return harness;
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
    final harness = await _served();
    final server = harness.server!;

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
    final harness = await _served();
    final server = harness.server!;

    final url = server.url('/img/two.jpg');
    harness.fetch(1, url);
    expect(await harness.eventFor(1), isA<ResultEvent>());
    harness.fetch(2, url);
    final second = await harness.eventFor(2) as ResultEvent;
    expect(await File(second.path).readAsBytes(), onePixelPng);
    expect(server.hits['/img/two.jpg'], 1);
  });

  test('a disk hit answers while every lane is busy', () async {
    final harness = await _served();
    final server = harness.server!;

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
      final harness = await _served();
      final server = harness.server!;

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

  // A network change closes the route pools under every image in flight;
  // each spent one of its visible image's retries on it.
  for (final (name, change) in [
    ('a fetch the network changed under is sent once more', true),
    ('a fetch failing on the same network fails at once', false),
  ]) {
    test(name, () async {
      final client = _FirstBodyBreaksClient();
      final harness = _Harness();
      addTearDown(harness.stop);
      await harness.start(fetchClient: () => client);

      harness.fetch(1, 'https://i.pximg.net/img-master/switch.jpg');
      await pollUntil(() => client.requests == 1);
      if (change) harness.worker.send(encodeConfig(_otherNetwork));
      // Messages are handled in order: once this answers, the config is in
      // force.
      harness.worker.send(encodeRoutesRequest(9));
      await harness.eventFor(9);
      client.breakFirst();
      expect(
        await harness.eventFor(1),
        change ? isA<ResultEvent>() : isA<FailureEvent>(),
      );
      expect(client.requests, change ? 2 : 1);
    });
  }

  test('a prefetch reaches the network as one', () async {
    final client = _RecordingImageClient();
    final harness = _Harness();
    addTearDown(harness.stop);
    await harness.start(fetchClient: () => client);

    harness.fetch(
      1,
      'https://i.pximg.net/img-master/prefetch.jpg',
      priority: ImageFetchPriority.background,
    );
    await harness.eventFor(1);
    harness.fetch(2, 'https://i.pximg.net/img-master/visible.jpg');
    await harness.eventFor(2);
    expect(
      [for (final r in client.requests) (r as ImageRequest).background],
      [true, false],
    );
  });

  test(
    'route samples go back to the main isolate under their network',
    () async {
      final harness = _Harness();
      addTearDown(harness.stop);
      await harness.start(
        config: _routedOn('home'),
        clientFactory: (_, _, _) => _RecordingImageClient(),
      );

      harness.fetch(1, 'https://i.pximg.net/img-master/img/a_p0.jpg');
      await harness.eventFor(1);
      harness.worker.send(encodeConfig(_routedOn('cafe')));
      harness.fetch(2, 'https://i.pximg.net/img-master/img/b_p0.jpg');
      await harness.eventFor(2);
      expect(
        harness._received.whereType<ImageRouteSampleEvent>().map(
          (e) => (e.networkIdentity, e.sample.candidate, e.sample.failed),
        ),
        [('home', 'origin', false), ('cafe', 'origin', false)],
      );
    },
  );

  test('a cancelled queued fetch never reaches the network', () async {
    final harness = await _served();
    final server = harness.server!;

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
    const size = 3 * (1 << 20) + 12345;

    Future<_Harness> started(RangeServingClient client) async {
      final harness = _Harness();
      addTearDown(harness.stop);
      await harness.start(fetchClient: () => client);
      return harness;
    }

    test('arrives whole on one range request, its progress against the '
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
      expect(client.ranges, ['bytes=0-']);
      // It is a pixiv image request that keeps to one route.
      expect(
        client.requests.map((r) => r.headers['referer']),
        everyElement(PixivHeaders.image()['Referer']),
      );
      expect(
        {for (final r in client.requests) (r as ImageRequest).pin},
        [isNotNull],
      );
      final progress = harness.takeProgress();
      expect(progress, isNotEmpty);
      expect(progress.map((p) => p.total), everyElement(size));
      expect(progress.last.received, lessThanOrEqualTo(size));
    });

    test('a dropped connection continues from its received byte on the '
        'same route, asking If-Range', () async {
      final bytes = patternBytes(size);
      final client = RangeServingClient({original: bytes})
        ..failOnceAt = 1 << 20;
      final harness = await started(client);

      harness
        ..watch(original)
        ..fetch(1, original);
      final result = await harness.eventFor(1) as ResultEvent;
      expect(await File(result.path).readAsBytes(), bytes);
      expect(client.ranges, ['bytes=0-', 'bytes=${1 << 20}-']);
      expect(client.requests.last.headers['if-range'], '"v1"');
      expect({
        for (final r in client.requests) (r as ImageRequest).pin,
      }, hasLength(1));
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
  });

  test(
    'an original nobody wants stops, and asking again starts afresh',
    () async {
      const original = 'https://i.pximg.net/img-original/big_p0.png';
      final bytes = patternBytes(3 << 20);
      final client = RangeServingClient({original: bytes}, hold: true);
      final harness = _Harness();
      addTearDown(harness.stop);
      await harness.start(fetchClient: () => client);

      harness.fetch(1, original);
      await pollUntil(() => client.readHeld == 1);
      harness.cancel(1);
      await pollUntil(() => client.readHeld == 0);
      // The partial file is gone with the transfer.
      await pollUntil(() => harness.dir.listSync().isEmpty);

      final opened = client.requests.length;
      harness.fetch(2, original);
      await pollUntil(() => client.requests.length > opened);
      expect(client.ranges[opened], 'bytes=0-');
      final result = harness.eventFor(2);
      var done = false;
      unawaited(result.whenComplete(() => done = true));
      while (!done) {
        client.releaseHeld();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        await File((await result as ResultEvent).path).readAsBytes(),
        bytes,
      );
    },
  );

  test('a lookup answers from disk and never fetches', () async {
    final harness = await _served();
    final server = harness.server!;
    final url = server.url('/img/cached.jpg');

    harness.lookup(1, url);
    expect((await harness.eventFor(1) as CachedEvent).path, isNull);
    expect(server.hits, isEmpty);

    harness.fetch(2, url);
    final fetched = await harness.eventFor(2) as ResultEvent;
    harness.lookup(3, url);
    expect((await harness.eventFor(3) as CachedEvent).path, fetched.path);
    expect(server.hits['/img/cached.jpg'], 1);
  });

  test('a route request answers the policy\'s routes', () async {
    // Nothing was fetched, so the real policy has settled no route yet:
    // the answer is an empty map, not silence.
    final harness = _Harness();
    addTearDown(harness.stop);
    await harness.start();

    harness.worker.send(encodeRoutesRequest(4));
    expect((await harness.eventFor(4) as RoutesEvent).routes, isEmpty);
  });

  test('a worker scores its image routes from its config, network by '
      'network', () async {
    ImageWorkerConfig scored(String network, double cost) => _routedOn(
      network,
      scores: {
        'origin': ImageRouteScore(
          cost: cost,
          weight: ImageRouteScores.maxWeight,
          failureShare: 0.5,
          at: DateTime.now(),
        ),
      },
    );
    final harness = _Harness();
    addTearDown(harness.stop);
    await harness.start(config: scored('home', 0.5));
    Future<ImageRouteStanding> origin(int id) async {
      harness.worker.send(encodeRoutesRequest(id));
      return (await harness.eventFor(id) as RoutesEvent).images.single;
    }

    final home = await origin(1);
    expect(home.cloudflare, isNull);
    expect(home.cost, closeTo(0.5, 0.01));
    expect(home.failureShare, closeTo(0.5, 0.01));
    harness.worker.send(encodeConfig(scored('cafe', 4)));
    expect((await origin(2)).cost, closeTo(4, 0.01));
  });

  test('watch, progress, lookup, route and config messages survive the '
      'wire', () {
    for (final watching in [true, false]) {
      expect(
        decodeWorkerMessage(encodeWatch('u', watching: watching)),
        isA<WatchMessage>()
            .having((m) => m.url, 'url', 'u')
            .having((m) => m.watching, 'watching', watching),
      );
    }
    expect(
      decodeWorkerMessage(encodeLookup(7, 'u')),
      isA<LookupMessage>()
          .having((m) => m.id, 'id', 7)
          .having((m) => m.url, 'url', 'u'),
    );
    expect(
      decodeWorkerMessage(encodeRoutesRequest(8)),
      isA<RoutesMessage>().having((m) => m.id, 'id', 8),
    );
    expect(
      decodeWorkerEvent(encodeWorkerEvent(const RoutesEvent(8, {'h': 'ech'}))),
      isA<RoutesEvent>().having((e) => e.id, 'id', 8).having(
        (e) => e.routes,
        'routes',
        {'h': 'ech'},
      ),
    );
    expect(
      decodeWorkerEvent(
        encodeWorkerEvent(
          const ImageRouteRangesEvent('home', 'origin', served: false),
        ),
      ),
      isA<ImageRouteRangesEvent>().having(
        (e) => (e.networkIdentity, e.candidate, e.served),
        'fields',
        ('home', 'origin', false),
      ),
    );
    final score = ImageRouteScore(
      cost: 0.5,
      weight: 3,
      failureShare: 0,
      at: DateTime(2026, 11, 4),
      servesRanges: false,
    );
    final config = ImageWorkerConfig.fromJson(
      ImageWorkerConfig(
        imageSource: 'i.pximg.net',
        mode: 'automatic',
        networkIdentity: 'home',
        echFrontHost: 'cloudflare-ech.com',
        dohEndpoints: const [],
        bootstrapNoSniEnabled: true,
        routeScores: {'origin': score},
      ).toJson(),
    );
    expect(config.routeScores.keys, ['origin']);
    expect(config.routeScores['origin']!.toJson(), score.toJson());
    for (final path in ['/cache/a', null]) {
      expect(
        decodeWorkerEvent(encodeWorkerEvent(CachedEvent(7, path))),
        isA<CachedEvent>()
            .having((e) => e.id, 'id', 7)
            .having((e) => e.path, 'path', path),
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
