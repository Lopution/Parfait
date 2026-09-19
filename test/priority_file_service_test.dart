import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pixiv_func/core/network/compat/image_cache.dart';

/// Sends return immediately; each response body stays open until the test
/// closes its controller, so a lane permit is observably held for the whole
/// transfer — not just the header wait.
class _HeldBodyClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final bodies = <StreamController<List<int>>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final body = StreamController<List<int>>();
    bodies.add(body);
    return http.StreamedResponse(body.stream, 200, request: request);
  }
}

void main() {
  test('marker header is stripped before the request is sent', () async {
    final client = _HeldBodyClient();
    final service = PriorityFileService(httpClient: client);

    final response = await service.get(
      'https://i.pximg.net/a.jpg',
      headers: {PriorityFileService.prefetchMarker: '1', 'x-keep': 'v'},
    );
    final drained = response.content.drain<void>();
    await client.bodies.single.close();
    await drained;

    expect(
      client.requests.single.headers[PriorityFileService.prefetchMarker],
      isNull,
    );
    expect(client.requests.single.headers['x-keep'], 'v');
  });

  test(
    'prefetch lane is capped while the foreground lane stays open',
    () async {
      final client = _HeldBodyClient();
      final service = PriorityFileService(httpClient: client);

      Map<String, String> prefetch() => {
        PriorityFileService.prefetchMarker: '1',
      };
      final responses = <FileServiceResponse>[];
      // Saturate the background lane; the fourth prefetch must queue.
      for (var i = 0; i < PriorityFileService.backgroundSlots; i++) {
        responses.add(
          await service.get('https://i.pximg.net/p$i.jpg', headers: prefetch()),
        );
      }
      var queuedResolved = false;
      final queued = service
          .get('https://i.pximg.net/p_queued.jpg', headers: prefetch())
          .then((r) {
            queuedResolved = true;
            return r;
          });
      await Future<void>.delayed(Duration.zero);
      expect(queuedResolved, isFalse);

      // A visible load is not stuck behind the prefetch backlog.
      final visible = await service.get('https://i.pximg.net/v.jpg');
      final visibleDrained = visible.content.drain<void>();
      await client.bodies[3].close();
      await visibleDrained;

      // The permit is held for the whole transfer: consuming and closing one
      // prefetch body is what frees the lane.
      final drained = responses.first.content.drain<void>();
      await client.bodies.first.close();
      await drained;
      final queuedResponse = await queued;
      expect(queuedResolved, isTrue);
      final queuedDrained = queuedResponse.content.drain<void>();
      await client.bodies.last.close();
      await queuedDrained;
    },
  );

  test('cancelling an unread prefetch body releases the lane', () async {
    final client = _HeldBodyClient();
    final service = PriorityFileService(httpClient: client);
    Map<String, String> prefetch() => {PriorityFileService.prefetchMarker: '1'};

    final responses = <FileServiceResponse>[];
    for (var i = 0; i < PriorityFileService.backgroundSlots; i++) {
      responses.add(
        await service.get('https://i.pximg.net/c$i.jpg', headers: prefetch()),
      );
    }
    // Consume nothing on the first response; cancelling its subscription
    // must still free the permit.
    final sub = responses.first.content.listen((_) {});
    await sub.cancel();

    final next = await service.get(
      'https://i.pximg.net/c_next.jpg',
      headers: prefetch(),
    );
    final nextDrained = next.content.drain<void>();
    await client.bodies.last.close();
    await nextDrained;
    for (final body in client.bodies) {
      if (!body.isClosed) unawaited(body.close());
    }
  });
}
