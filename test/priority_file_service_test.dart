import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/network/compat/image_cache.dart';

import 'helpers/image_network.dart';

Map<String, String> _prefetch() => {PriorityFileService.prefetchMarker: '1'};

/// A [PriorityFileService] over a [HeldBodyClient] that remembers every
/// response it hands out, so a test can release all lane permits at the end
/// instead of leaving them to the 45 s hold limit.
class _Lanes {
  _Lanes() {
    service = PriorityFileService(httpClient: client);
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
}
