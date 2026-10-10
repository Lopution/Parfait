import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/image/image_worker.dart';
import 'package:parfait/core/image/image_worker_client.dart';
import 'package:parfait/core/image/image_worker_host.dart';
import 'package:parfait/core/image/image_worker_protocol.dart';
import 'package:parfait/core/image/lane_permit_gate.dart';
import 'package:parfait/core/image/image_demand.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';

import 'helpers/image_network.dart';
import 'helpers/worker_entries.dart';

const _url = 'https://i.pximg.net/img-master/a.jpg';

/// Starts workers the way production does, one script entry per start:
/// a real isolate for [readyThenExitWorkerEntry], an in-process host
/// serving a PNG for null.
class _Starts {
  _Starts(this.script);

  final List<void Function(Map<String, Object?>)?> script;
  final hosts = <ImageWorkerHost>[];
  final configs = <ImageWorkerConfig>[];
  late final dir = Directory.systemTemp.createTempSync('parfait-handle-');

  Future<ImageWorkerClient> call(ImageWorkerConfig config, ImageDemand demand) {
    final entry = script[configs.length];
    configs.add(config);
    if (entry != null) {
      return ImageWorkerClient.start(
        config: config,
        cacheDir: dir.path,
        demand: demand,
        entry: entry,
      );
    }
    final inbox = ReceivePort();
    final host = ImageWorkerHost(
      mainSendPort: inbox.sendPort,
      config: config,
      cacheDir: dir.path,
      transportInit: () async {},
      fetchClient: () =>
          MockClient((_) async => http.Response.bytes(onePixelPng, 200)),
    );
    hosts.add(host);
    unawaited(host.run());
    return ImageWorkerClient.attach(inbox, demand: demand);
  }

  Future<void> close() async {
    for (final host in hosts) {
      await host.close();
    }
    await dir.delete(recursive: true);
  }
}

ImageWorker _worker(
  Future<ImageWorkerClient> Function(ImageWorkerConfig, ImageDemand) start, {
  Future<ImageWorkerConfig> Function()? config,
}) {
  final worker = ImageWorker(
    start: start,
    config: config ?? () async => testImageWorkerConfig,
  );
  addTearDown(worker.dispose);
  return worker;
}

Future<FetchResult> _fetch(ImageWorker worker, [String url = _url]) =>
    worker.fetch(url, priority: ImageFetchPriority.foreground);

/// Upper bound for an isolate exit to reach the client.
const _exitBound = Duration(seconds: 5);

void main() {
  test('requests during a start share one worker', () async {
    final starts = _Starts([null]);
    addTearDown(starts.close);
    final worker = _worker(starts.call);

    final results = await Future.wait([
      _fetch(worker),
      _fetch(worker, 'https://i.pximg.net/img-master/b.jpg'),
    ]);
    expect(results.map((r) => r.bytes), everyElement(onePixelPng.length));
    expect(worker.starts, 1);
  });

  test('a worker that dies is replaced on the next request', () async {
    final starts = _Starts([readyThenExitWorkerEntry, null]);
    addTearDown(starts.close);
    final worker = _worker(starts.call);

    // The first worker exits on its first message: that request fails
    // loudly, it is not retried behind the caller's back.
    await expectLater(_fetch(worker), throwsA(isA<ImageWorkerUnavailable>()));
    final deadline = DateTime.now().add(_exitBound);
    while (worker.live != null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(worker.live, isNull);

    final result = await _fetch(worker);
    expect(result.bytes, onePixelPng.length);
    expect(worker.starts, 2);
  });

  test('progress reaches each watcher of a URL until it stops', () async {
    final starts = _Starts([null]);
    addTearDown(starts.close);
    final worker = _worker(starts.call);
    final first = <(int, int?)>[];
    final second = <(int, int?)>[];
    final stopFirst = worker.watchProgress(_url, (r, t) => first.add((r, t)));
    final stopSecond = worker.watchProgress(_url, (r, t) => second.add((r, t)));
    addTearDown(stopSecond);
    stopFirst();

    await _fetch(worker);
    expect(first, isEmpty);
    expect(second, [(onePixelPng.length, onePixelPng.length)]);
  });

  test('every worker that starts is told the watched URLs, a replacement '
      'included', () async {
    final starts = _Starts([readyThenExitWorkerEntry, null]);
    addTearDown(starts.close);
    final worker = _worker(starts.call);
    final reports = <int>[];
    addTearDown(
      worker.watchProgress(_url, (received, _) => reports.add(received)),
    );

    await expectLater(_fetch(worker), throwsA(isA<ImageWorkerUnavailable>()));
    final deadline = DateTime.now().add(_exitBound);
    while (worker.live != null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(worker.live, isNull);

    await _fetch(worker);
    expect(worker.starts, 2);
    expect(reports, [onePixelPng.length]);
  });

  test('a cache lookup starts the worker and answers from its disk', () async {
    final starts = _Starts([null]);
    addTearDown(starts.close);
    final worker = _worker(starts.call);

    expect(await worker.cachedFile(_url), isNull);
    expect(worker.starts, 1);
    final result = await _fetch(worker);
    expect((await worker.cachedFile(_url))?.path, result.file.path);
  });

  test('failed starts are retried until the budget is spent', () async {
    var calls = 0;
    final worker = _worker((_, _) async {
      calls++;
      throw const FileSystemException('no cache directory');
    });

    for (var i = 0; i < ImageWorker.defaultMaxStarts; i++) {
      await expectLater(
        _fetch(worker),
        throwsA(
          isA<ImageWorkerUnavailable>().having(
            (e) => e.reason,
            'reason',
            contains('start failed'),
          ),
        ),
      );
    }
    // Past the budget no start is attempted; the error names the cause.
    await expectLater(
      _fetch(worker),
      throwsA(
        isA<ImageWorkerUnavailable>().having(
          (e) => e.reason,
          'reason',
          allOf(contains('gave up after 3 starts'), contains('no cache')),
        ),
      ),
    );
    expect(calls, ImageWorker.defaultMaxStarts);
  });

  test('a config change reaches the running worker', () async {
    final starts = _Starts([null]);
    addTearDown(starts.close);
    var source = 'i.pximg.net';
    final worker = _worker(
      starts.call,
      config: () async => ImageWorkerConfig(
        imageSource: source,
        mode: testImageWorkerConfig.mode,
        networkIdentity: testImageWorkerConfig.networkIdentity,
        echFrontHost: testImageWorkerConfig.echFrontHost,
        dohEndpoints: testImageWorkerConfig.dohEndpoints,
        bootstrapNoSniEnabled: true,
      ),
    );

    // Nothing runs yet: the change waits for the start to read it.
    source = 'i.pixiv.re';
    await worker.configChanged();
    expect(starts.configs, isEmpty);

    await _fetch(worker);
    expect(starts.configs.single.imageSource, 'i.pixiv.re');

    source = 'i.pixiv.cat';
    await worker.configChanged();
    final host = starts.hosts.single;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (host.config.imageSource != 'i.pixiv.cat' &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(host.config.imageSource, 'i.pixiv.cat');
  });

  test('a snapshot never starts a worker', () async {
    final worker = _worker((_, _) => fail('the probe started a worker'));
    final snapshot = await worker.snapshot();
    expect(snapshot.state, ImageWorkerState.idle);
    expect(snapshot.describe(), 'image worker: idle, starts 0/3\n');
  });

  test('route snapshots never start a worker', () async {
    final worker = _worker((_, _) => fail('the network page started a worker'));
    expect(await worker.routeSnapshot(), isEmpty);
    expect(worker.starts, 0);
  });

  test('a route snapshot comes from the running worker', () async {
    final worker = _worker(
      (_, demand) =>
          scriptedImageWorkerClient(demand, routes: {'i.pximg.net': 'noSni'}),
    );
    await worker.cachedFile(_url);

    expect(await worker.routeSnapshot(), {
      'i.pximg.net': NetworkRouteKind.noSni,
    });
  });

  test('a snapshot reports the running worker\'s queue and disk', () async {
    final starts = _Starts([null]);
    addTearDown(starts.close);
    final worker = _worker(starts.call);
    await _fetch(worker);

    final snapshot = await worker.snapshot();
    expect(snapshot.state, ImageWorkerState.running);
    final status = snapshot.status!;
    expect((status.inFlight, status.queued), (0, 0));
    expect(status.diskEntries, 1);
    expect(status.diskBytes, onePixelPng.length);
    expect(
      snapshot.describe(),
      'image worker: running, starts 1/3\n'
      '  in flight 0, queued 0\n'
      '  disk 1 files, 0.0 / 256.0 MB\n',
    );
  });

  test('a start that lands after dispose is torn down', () async {
    final started = Completer<ImageWorkerClient>();
    final starts = _Starts([null]);
    addTearDown(starts.close);
    final worker = _worker((config, demand) {
      started.complete(starts(config, demand));
      return started.future;
    });

    final pending = _fetch(worker);
    await worker.dispose();
    await expectLater(pending, throwsA(isA<ImageWorkerUnavailable>()));
    expect((await started.future).isDead, isTrue);
    await expectLater(_fetch(worker), throwsA(isA<ImageWorkerUnavailable>()));
  });
}
