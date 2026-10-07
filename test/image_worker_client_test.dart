import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:parfait/core/image/image_worker_client.dart';
import 'package:parfait/core/image/image_worker_host.dart';
import 'package:parfait/core/image/image_worker_protocol.dart';
import 'package:parfait/core/image/lane_permit_gate.dart';
import 'package:parfait/core/network/compat/image_demand.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';

import 'helpers/image_network.dart';
import 'helpers/worker_entries.dart';

/// A loopback image server; `/hold/<x>` responses stay open until
/// [release]/[releasePath] so lane occupancy is deterministic.
class _Server {
  final hits = <String, int>{};
  final _held = <String, HttpResponse>{};
  late final HttpServer inner;

  Future<void> start() async {
    inner = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      inner.forEach((request) async {
        final path = request.uri.path;
        hits[path] = (hits[path] ?? 0) + 1;
        if (path.startsWith('/hold/')) {
          _held[path] = request.response;
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

  /// Answers the held response for [path], freeing one lane slot.
  void releasePath(String path) {
    _answer(_held.remove(path)!);
  }

  void _answer(HttpResponse response) {
    response
      ..contentLength = onePixelPng.length
      ..add(onePixelPng);
    unawaited(response.close());
  }

  void release() {
    for (final response in _held.values.toList()) {
      _answer(response);
    }
    _held.clear();
  }

  Future<void> stop() async {
    release();
    await inner.close(force: true);
  }
}

/// An in-process worker host wired to a client through the real protocol.
class _Harness {
  late final ImageWorkerHost host;
  late final ImageWorkerClient client;
  final demand = ImageDemand();
  late final Directory dir;
  _Server? server;

  Future<void> start({http.Client Function()? fetchClient}) async {
    dir = Directory.systemTemp.createTempSync('parfait-client-');
    addTearDown(() => dir.delete(recursive: true));
    final inbox = ReceivePort();
    host = ImageWorkerHost(
      mainSendPort: inbox.sendPort,
      config: testImageWorkerConfig,
      cacheDir: dir.path,
      transportInit: () async {},
      fetchClient: fetchClient ?? IOClient.new,
    );
    unawaited(host.run());
    client = await ImageWorkerClient.attach(inbox, demand: demand);
  }

  Future<void> stop() async {
    await server?.stop();
    await client.dispose();
    await host.close();
  }
}

void main() {
  test('a fetch returns the committed file path and bytes', () async {
    final harness = _Harness();
    addTearDown(harness.stop);
    final server = _Server();
    await server.start();
    harness.server = server;
    await harness.start();

    final result = await harness.client.fetch(
      server.url('/img/a.jpg'),
      priority: ImageFetchPriority.foreground,
    );
    expect(await result.file.readAsBytes(), onePixelPng);
    expect(result.bytes, onePixelPng.length);
    expect(server.hits['/img/a.jpg'], 1);
  });

  test('concurrent requests for one URL share a single network hit', () async {
    final harness = _Harness();
    addTearDown(harness.stop);
    final server = _Server();
    await server.start();
    harness.server = server;
    await harness.start();

    final a = harness.client.fetch(
      server.url('/img/dup.jpg'),
      priority: ImageFetchPriority.foreground,
    );
    final b = harness.client.fetch(
      server.url('/img/dup.jpg'),
      priority: ImageFetchPriority.foreground,
    );
    final results = await Future.wait([a, b]);
    expect(server.hits['/img/dup.jpg'], 1);
    expect(results[0].bytes, onePixelPng.length);
    expect(results[1].bytes, onePixelPng.length);
  });

  test('an HTTP error surfaces as FetchFailure with its status', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    unawaited(
      server.forEach((request) async {
        request.response.statusCode = 404;
        await request.response.close();
      }),
    );
    final harness = _Harness();
    addTearDown(harness.stop);
    await harness.start();

    await expectLater(
      harness.client.fetch(
        'http://127.0.0.1:${server.port}/gone.jpg',
        priority: ImageFetchPriority.foreground,
      ),
      throwsA(
        isA<FetchFailure>()
            .having((f) => f.statusCode, 'statusCode', 404)
            .having((f) => f.isPermanent, 'isPermanent', isTrue),
      ),
    );
  });

  test('cancelUrl drops a queued request and completes it dropped', () async {
    final harness = _Harness();
    addTearDown(harness.stop);
    final server = _Server();
    await server.start();
    harness.server = server;
    await harness.start();

    for (var i = 0; i < 8; i++) {
      unawaited(
        harness.client.fetch(
          server.url('/hold/$i.jpg'),
          priority: ImageFetchPriority.foreground,
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(server.hits.length, 8);

    final queued = harness.client.fetch(
      server.url('/img/queued.jpg'),
      priority: ImageFetchPriority.foreground,
    );
    harness.client.cancelUrl(server.url('/img/queued.jpg'));
    await expectLater(queued, throwsA(isA<ImageFetchDropped>()));
    server.release();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.hits.containsKey('/img/queued.jpg'), isFalse);
  });

  test('a released URL is cancelled once the release grace elapses', () async {
    final harness = _Harness();
    addTearDown(harness.stop);
    final server = _Server();
    await server.start();
    harness.server = server;
    await harness.start();

    final url = server.url('/hold/released.jpg');
    harness.demand.hold(url);
    final pending = harness.client.fetch(
      url,
      priority: ImageFetchPriority.foreground,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.hits['/hold/released.jpg'], 1);

    // While it is streaming the release does nothing — the transfer still
    // lands in the disk cache for the next visit.
    harness.demand.release(url);
    server.release();
    await pending;
    await Future<void>.delayed(
      releaseGrace + const Duration(milliseconds: 100),
    );
    // No cancel raced the completed request.
    expect(harness.client.pendingCount, 0);
  });

  test(
    'a queued request dies when its URL leaves the prefetch window',
    () async {
      final harness = _Harness();
      addTearDown(harness.stop);
      final server = _Server();
      await server.start();
      harness.server = server;
      await harness.start();

      // Occupy both background slots so the prefetch request queues.
      final held = <Future<FetchResult>>[];
      for (var i = 0; i < 2; i++) {
        held.add(
          harness.client.fetch(
            server.url('/hold/bg$i.jpg'),
            priority: ImageFetchPriority.background,
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final queuedUrl = server.url('/img/prefetch.jpg');
      harness.demand.setPrefetchWindow(harness, {queuedUrl});
      final queued = harness.client.fetch(
        queuedUrl,
        priority: ImageFetchPriority.background,
      );

      // The window moves on — the queued prefetch is cancelled at once.
      harness.demand.setPrefetchWindow(harness, {server.url('/img/next.jpg')});
      await expectLater(queued, throwsA(isA<ImageFetchDropped>()));
      server.release();
      await Future.wait(held);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.hits.containsKey('/img/prefetch.jpg'), isFalse);
    },
  );

  test(
    'promoteUrl lifts a queued background fetch onto the foreground',
    () async {
      final harness = _Harness();
      addTearDown(harness.stop);
      final server = _Server();
      await server.start();
      harness.server = server;
      await harness.start();

      // Both background slots occupied; the warm fetch queues behind them.
      final background = <Future<FetchResult>>[
        for (var i = 0; i < 2; i++)
          harness.client.fetch(
            server.url('/hold/bg$i.jpg'),
            priority: ImageFetchPriority.background,
          ),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final warmUrl = server.url('/img/warm.jpg');
      final queued = harness.client.fetch(
        warmUrl,
        priority: ImageFetchPriority.background,
      );
      // Every foreground slot is occupied too — nothing frees on its own.
      final foreground = <Future<FetchResult>>[
        for (var i = 0; i < 8; i++)
          harness.client.fetch(
            server.url('/hold/fg$i.jpg'),
            priority: ImageFetchPriority.foreground,
          ),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.hits.length, 10);
      expect(server.hits.containsKey('/img/warm.jpg'), isFalse);

      harness.client.promoteUrl(warmUrl);
      // Releasing ONE foreground hold admits the promoted waiter — while the
      // background lane stays full. Without promotion the warm fetch would
      // still be waiting on a background slot.
      server.releasePath('/hold/fg0.jpg');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(server.hits['/img/warm.jpg'], 1);

      server.release();
      await Future.wait([...background, ...foreground]);
      final warm = await queued.timeout(const Duration(seconds: 5));
      expect(warm.bytes, onePixelPng.length);
    },
  );

  test('a worker that exits during init fails the start at once', () async {
    final dir = Directory.systemTemp.createTempSync('parfait-client-exit-');
    addTearDown(() => dir.delete(recursive: true));
    final started = DateTime.now();
    await expectLater(
      ImageWorkerClient.start(
        config: testImageWorkerConfig,
        cacheDir: dir.path,
        demand: ImageDemand(),
        entry: exitAtOnceWorkerEntry,
      ),
      throwsA(isA<ImageWorkerUnavailable>()),
    );
    // Well inside the 15 s ready timeout: the exit itself failed it.
    expect(DateTime.now().difference(started), lessThan(_exitBound));
  });

  test('dispose fails the requests still pending', () async {
    final harness = _Harness();
    // The network never answers.
    await harness.start(
      fetchClient: () => MockClient((_) => Completer<http.Response>().future),
    );
    addTearDown(harness.host.close);
    final pending = harness.client.fetch(
      'https://i.pximg.net/a.jpg',
      priority: ImageFetchPriority.foreground,
    );
    final status = harness.client.status();
    final failures = [
      expectLater(pending, throwsA(isA<ImageWorkerUnavailable>())),
      expectLater(status, throwsA(isA<ImageWorkerUnavailable>())),
    ];
    await harness.client.dispose();
    await Future.wait(failures);
  });

  test('route snapshots arrive as route kinds by host', () async {
    final client = await scriptedImageWorkerClient(
      ImageDemand(),
      routes: {'i.pximg.net': 'ech', 'i.pixiv.cat': 'direct'},
    );
    addTearDown(client.dispose);

    expect(await client.routeSnapshot(), {
      'i.pximg.net': NetworkRouteKind.ech,
      'i.pixiv.cat': NetworkRouteKind.direct,
    });
  });

  test('a disposed client fails route questions at once', () async {
    final client = await scriptedImageWorkerClient(ImageDemand());
    await client.dispose();

    await expectLater(
      client.routeSnapshot(),
      throwsA(isA<ImageWorkerUnavailable>()),
    );
  });

  test('a worker that dies fails pending and later requests loudly', () async {
    final dir = Directory.systemTemp.createTempSync('parfait-client-dies-');
    addTearDown(() => dir.delete(recursive: true));
    final client = await ImageWorkerClient.start(
      config: testImageWorkerConfig,
      cacheDir: dir.path,
      demand: ImageDemand(),
      entry: readyThenExitWorkerEntry,
    );
    addTearDown(client.dispose);
    final died = Completer<Object>();
    client.onDied = died.complete;

    final pending = client.fetch(
      'https://i.pximg.net/a.jpg',
      priority: ImageFetchPriority.foreground,
    );
    await expectLater(pending, throwsA(isA<ImageWorkerUnavailable>()));
    expect(
      await died.future.timeout(_exitBound),
      isA<ImageWorkerUnavailable>(),
    );
    expect(client.isDead, isTrue);
    await expectLater(
      client.fetch(
        'https://i.pximg.net/b.jpg',
        priority: ImageFetchPriority.foreground,
      ),
      throwsA(isA<ImageWorkerUnavailable>()),
    );
  });
}

/// Upper bound for an isolate exit to reach the client.
const _exitBound = Duration(seconds: 5);
