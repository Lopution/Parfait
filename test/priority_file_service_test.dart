import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/network/compat/image_cache.dart';
import 'package:parfait/core/network/compat/image_demand.dart';
import 'package:parfait/core/network/compat/segmented_fetch.dart';

import 'helpers/image_network.dart';

Map<String, String> _prefetch() => {PriorityFileService.prefetchMarker: '1'};

/// A [PriorityFileService] over a [HeldBodyClient] that remembers every
/// response it hands out, so a test can release all lane permits at the end
/// instead of leaving them to the 45 s hold limit.
class _Lanes {
  _Lanes({ImageDemand? demand}) {
    service = PriorityFileService(httpClient: client, demand: demand);
  }

  final client = HeldBodyClient();
  late final PriorityFileService service;
  final _responses = <FileServiceResponse>[];
  final _urls = <FileServiceResponse, String>{};
  final _settled = <FileServiceResponse>{};

  Future<FileServiceResponse> get(String url, {bool prefetch = true}) async {
    final response = await service.get(
      url,
      headers: prefetch ? _prefetch() : null,
    );
    _responses.add(response);
    _urls[response] = url;
    return response;
  }

  /// Fills the background lane with held transfers.
  Future<void> saturateBackground() async {
    for (var i = 0; i < PriorityFileService.backgroundSlots; i++) {
      await get('https://i.pximg.net/busy$i.jpg');
    }
  }

  /// Streams [response] to the end.
  Future<void> finish(FileServiceResponse response) async {
    _settled.add(response);
    final index = client.urls.lastIndexOf(_urls[response]!);
    final drained = response.content.drain<void>();
    await client.bodies[index].close();
    await drained;
  }

  /// Abandons [response] without reading it.
  Future<void> cancel(FileServiceResponse response) async {
    _settled.add(response);
    await response.content.listen(null).cancel();
  }

  /// Cancels every open response, which releases its permit and admits the
  /// next waiter; repeats until nothing more was admitted.
  Future<void> dispose() async {
    var released = 0;
    while (released < _responses.length) {
      final response = _responses[released++];
      if (!_settled.contains(response)) await cancel(response);
      await settleIo(2);
    }
    await client.closeAll();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Lanes lanes;
  setUp(() => lanes = _Lanes());
  tearDown(() => lanes.dispose());

  test('marker header is stripped before the request is sent', () async {
    final response = await lanes.service.get(
      'https://i.pximg.net/a.jpg',
      headers: {PriorityFileService.prefetchMarker: '1', 'x-keep': 'v'},
    );
    final drained = response.content.drain<void>();
    await lanes.client.bodies.single.close();
    await drained;

    final sent = lanes.client.requests.single;
    expect(sent.headers[PriorityFileService.prefetchMarker], isNull);
    expect(sent.headers['x-keep'], 'v');
  });

  test(
    'prefetch lane is capped while the foreground lane stays open',
    () async {
      await lanes.saturateBackground();
      var queuedResolved = false;
      final queued = lanes.get('https://i.pximg.net/p_queued.jpg').then((r) {
        queuedResolved = true;
        return r;
      });
      await settleIo();
      expect(queuedResolved, isFalse);

      // A visible load is not stuck behind the prefetch backlog.
      final visible = await lanes.get(
        'https://i.pximg.net/v.jpg',
        prefetch: false,
      );
      await lanes.finish(visible);
      await settleIo();
      expect(queuedResolved, isFalse);

      // The permit is held for the whole transfer: finishing one prefetch
      // body is what frees the lane.
      final first = lanes._responses.first;
      await lanes.finish(first);
      await settleIo();
      expect(queuedResolved, isTrue);
      await queued;
    },
  );

  test('cancelling an unread prefetch body releases the lane', () async {
    await lanes.saturateBackground();
    // Consume nothing on the first response; cancelling its subscription
    // must still free the permit.
    await lanes.cancel(lanes._responses.first);

    await lanes.get('https://i.pximg.net/c_next.jpg');
    expect(lanes.client.urls.last, 'https://i.pximg.net/c_next.jpg');
  });

  test('a promoted prefetch overtakes the background queue and gives its '
      'slot back to the foreground lane', () async {
    await lanes.saturateBackground();
    const other = 'https://i.pximg.net/other.jpg';
    const seen = 'https://i.pximg.net/seen.jpg';
    unawaited(lanes.get(other));
    final promoted = lanes.get(seen);
    await settleIo();
    expect(lanes.client.urls, isNot(contains(seen)));

    lanes.service.promote(seen);
    final response = await promoted;
    expect(lanes.client.urls.last, seen);
    expect(lanes.client.urls, isNot(contains(other)));

    // Finishing the promoted transfer frees a foreground slot, not a
    // background one: the other prefetch still waits.
    await lanes.finish(response);
    await settleIo();
    expect(lanes.client.urls, isNot(contains(other)));
  });

  test('a promoted prefetch queues behind visible loads when the foreground '
      'lane is full', () async {
    await lanes.saturateBackground();
    final visible = [
      for (var i = 0; i < PriorityFileService.foregroundSlots; i++)
        await lanes.get('https://i.pximg.net/v$i.jpg', prefetch: false),
    ];
    const seen = 'https://i.pximg.net/seen.jpg';
    unawaited(lanes.get(seen));
    await settleIo();
    lanes.service.promote(seen);
    await settleIo();
    expect(lanes.client.urls, isNot(contains(seen)));

    await lanes.finish(visible.first);
    await settleIo();
    expect(lanes.client.urls.last, seen);
  });

  test('promoting a URL that is not queued changes nothing', () async {
    await lanes.saturateBackground();
    lanes.service.promote('https://i.pximg.net/busy0.jpg');
    lanes.service.promote('https://i.pximg.net/unknown.jpg');
    const queued = 'https://i.pximg.net/queued.jpg';
    unawaited(lanes.get(queued));
    await settleIo();
    expect(lanes.client.urls, isNot(contains(queued)));
  });

  test('a visible image reaches the network while a prefetch burst is still '
      'queued in the cache manager', () async {
    final client = HeldBodyClient();
    final manager = testImageCacheManager(
      PriorityFileService(httpClient: client),
    );
    final subscriptions = [
      for (var i = 0; i < 20; i++)
        manager
            .getFileStream('https://i.pximg.net/w$i.jpg', headers: _prefetch())
            .listen((_) {}, onError: (_) {}),
    ];
    const visible = 'https://i.pximg.net/visible.jpg';
    subscriptions.add(
      manager.getFileStream(visible).listen((_) {}, onError: (_) {}),
    );
    await settleIo();

    expect(lanes.client.urls, isEmpty);
    expect(client.urls, contains(visible));
    expect(
      client.urls.where((u) => u.contains('/w')),
      hasLength(PriorityFileService.backgroundSlots),
    );

    // Let every transfer finish so no permit waits on the hold limit.
    while (client.bodies.any((b) => !b.isClosed)) {
      await client.closeAll();
      await settleIo();
    }
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  });

  group('with demand', () {
    late DateTime now;
    late ImageDemand demand;
    final window = Object();
    setUp(() async {
      await lanes.dispose();
      now = DateTime(2026, 10, 3);
      demand = ImageDemand(clock: () => now);
      lanes = _Lanes(demand: demand);
    });

    test('a queued prefetch whose window moved on is dropped at its turn '
        'and never reaches the network', () async {
      const stale = 'https://i.pximg.net/stale.jpg';
      const fresh = 'https://i.pximg.net/fresh.jpg';
      demand.setPrefetchWindow(window, {stale, fresh});
      await lanes.saturateBackground();
      final dropped = expectLater(
        lanes.get(stale),
        throwsA(isA<ImageFetchDropped>()),
      );
      final admitted = lanes.get(fresh);
      await settleIo();

      demand.setPrefetchWindow(window, {fresh});
      await lanes.finish(lanes._responses.first);
      await dropped;
      await admitted;
      expect(lanes.client.urls, isNot(contains(stale)));
      expect(lanes.client.urls.last, fresh);
    });

    test('a dropped waiter does not leak its slot', () async {
      const stale = 'https://i.pximg.net/stale.jpg';
      await lanes.saturateBackground();
      final dropped = expectLater(
        lanes.get(stale),
        throwsA(isA<ImageFetchDropped>()),
      );
      await settleIo();
      await lanes.finish(lanes._responses.first);
      await dropped;

      // The freed slot is open again: the next prefetch starts at once.
      await lanes.get('https://i.pximg.net/next.jpg');
    });

    test('a transfer already streaming is never interrupted', () async {
      const url = 'https://i.pximg.net/streaming.jpg';
      demand.setPrefetchWindow(window, {url});
      final response = await lanes.get(url);
      final received = <int>[];
      final done = response.content.listen(received.addAll).asFuture<void>();
      lanes.client.bodies.single.add([1, 2]);
      await settleIo();

      demand.clearPrefetchWindow(window);
      lanes.client.bodies.single.add([3]);
      await lanes.client.bodies.single.close();
      await done;
      lanes._settled.add(response);
      expect(received, [1, 2, 3]);
    });

    test('a URL released moments ago is still fetched; after the grace '
        'period it is dropped', () async {
      const recent = 'https://i.pximg.net/recent.jpg';
      const old = 'https://i.pximg.net/old.jpg';
      await lanes.saturateBackground();
      demand
        ..hold(old)
        ..release(old);
      now = now.add(const Duration(milliseconds: 200));
      demand
        ..hold(recent)
        ..release(recent);
      final dropped = expectLater(
        lanes.get(old),
        throwsA(isA<ImageFetchDropped>()),
      );
      final admitted = lanes.get(recent);
      await settleIo();

      // 600 ms after the first release, 400 ms after the second.
      now = now.add(const Duration(milliseconds: 400));
      await lanes.finish(lanes._responses.first);
      await dropped;
      await admitted;
      expect(lanes.client.urls.last, recent);
    });
  });

  test('a widget starting to show a queued prefetch promotes it', () async {
    mockPathProvider();
    final client = HeldBodyClient();
    final cache = PixivImageCache(httpClient: client);
    addTearDown(cache.dispose);
    final subscriptions = [
      for (var i = 0; i < PriorityFileService.backgroundSlots + 2; i++)
        cache.manager
            .getFileStream('https://i.pximg.net/w$i.jpg', headers: _prefetch())
            .listen((_) {}, onError: (_) {}),
    ];
    const seen =
        'https://i.pximg.net/w${PriorityFileService.backgroundSlots + 1}.jpg';
    await pollUntil(
      () => client.urls.length == PriorityFileService.backgroundSlots,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(client.urls, isNot(contains(seen)));

    cache.demand.hold(seen);
    await pollUntil(() => client.urls.contains(seen));
    expect(client.urls, hasLength(PriorityFileService.backgroundSlots + 1));

    while (client.bodies.any((b) => !b.isClosed)) {
      await client.closeAll();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  });

  group('originals', () {
    const original = 'https://i.pximg.net/img-original/img/1_p0.png';
    const preview = 'https://i.pximg.net/img-master/img/1_p0_master1200.jpg';
    final size = 3 * SegmentedFetch.defaultSegmentBytes + 12345;
    final firstRange = 'bytes=0-${SegmentedFetch.defaultSegmentBytes - 1}';

    Future<List<int>> read(FileServiceResponse response) async => [
      for (final chunk in await response.content.toList()) ...chunk,
    ];

    test('start with a ranged request and reach WebHelper as one 200 of '
        'the full length', () async {
      final data = patternBytes(size);
      final client = RangeServingClient({original: data});
      final budget = SegmentBudget();
      final service = PriorityFileService(
        httpClient: client,
        segmentBudget: budget,
      );
      final response = await service.get(original);
      expect(client.ranges.first, firstRange);
      expect(response.statusCode, 200);
      expect(response.contentLength, size);
      expect(await read(response), data);
      expect(client.requests, hasLength(4));
      expect(budget.inUse, 0);
    });

    test('land on disk byte for byte through the real cache manager', () async {
      final data = patternBytes(size);
      final client = RangeServingClient({original: data});
      final manager = testImageCacheManager(
        PriorityFileService(httpClient: client, segmentBudget: SegmentBudget()),
      );
      final file = await manager.getSingleFile(original);
      expect(await file.readAsBytes(), data);
      expect(client.ranges.first, firstRange);
    });

    test('a revalidation asks If-None-Match on the first range only', () async {
      final data = patternBytes(size);
      final client = RangeServingClient({original: data});
      final service = PriorityFileService(
        httpClient: client,
        segmentBudget: SegmentBudget(),
      );
      final response = await service.get(
        original,
        headers: {'If-None-Match': '"v0"'},
      );
      expect(await read(response), data);
      expect(
        [for (final r in client.requests) r.headers['if-none-match']],
        ['"v0"', null, null, null],
      );
      expect([
        for (final r in client.requests.skip(1)) r.headers['if-range'],
      ], everyElement('"v1"'));
    });

    test('other images are fetched without Range', () async {
      final data = patternBytes(size);
      final client = RangeServingClient({preview: data});
      final service = PriorityFileService(
        httpClient: client,
        segmentBudget: SegmentBudget(),
      );
      expect(await read(await service.get(preview)), data);
      expect(client.ranges, [null]);
    });

    test('a server that ignores Range streams the whole file once', () async {
      final data = patternBytes(size);
      final client = RangeServingClient({original: data}, honorRange: false);
      final service = PriorityFileService(
        httpClient: client,
        segmentBudget: SegmentBudget(),
      );
      final response = await service.get(original);
      expect(response.statusCode, 200);
      expect(await read(response), data);
      expect(client.requests, hasLength(1));
    });

    test('a segmented original holds one foreground slot', () async {
      final files = {
        original: patternBytes(size),
        for (var i = 0; i < PriorityFileService.foregroundSlots; i++)
          'https://i.pximg.net/img-master/v$i.jpg': patternBytes(10),
      };
      final client = RangeServingClient(files, hold: true);
      final service = PriorityFileService(
        httpClient: client,
        segmentBudget: SegmentBudget(),
      );
      final body = (await service.get(original)).content.drain<void>();
      await pollUntil(
        () => client.requests.length == SegmentedFetch.defaultParallel,
      );
      final others = [
        for (var i = 0; i < PriorityFileService.foregroundSlots; i++)
          service.get('https://i.pximg.net/img-master/v$i.jpg'),
      ];
      await settleIo();
      // Every slot but the original's is free for visible images.
      expect(
        client.urls.where((u) => u.contains('/v')),
        hasLength(PriorityFileService.foregroundSlots - 1),
      );
      while (client.urls.where((u) => u.contains('/v')).length <
          PriorityFileService.foregroundSlots) {
        client.releaseHeld();
        await settleIo();
      }
      client.releaseHeld();
      for (final response in await Future.wait(others)) {
        await response.content.drain<void>();
      }
      await body;
    });
  });
}
