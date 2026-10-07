import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/image_tier_cache.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/image/image_fetch_scheduler.dart';
import 'package:parfait/core/image/image_worker.dart';
import 'package:parfait/core/image/image_worker_providers.dart';

import 'helpers/image_network.dart';

const _backgroundSlots = ImageFetchScheduler.defaultBackgroundSlots;

/// Pumps a bare host on [worker] and returns a context
/// [PixivImage.preload] can use.
Future<BuildContext> _context(WidgetTester tester, ImageWorker worker) async {
  late BuildContext context;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [imageWorkerProvider.overrideWithValue(worker)],
      child: Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    ),
  );
  return context;
}

void main() {
  testWidgets('a failed preload stays out of the crash log and is not '
      'recorded as decoded', (tester) async {
    final client = HeldBodyClient(
      respond: (request) => http.StreamedResponse(
        Stream.value(const <int>[]),
        404,
        request: request,
      ),
    );
    final context = await _context(tester, inProcessImageWorker(() => client));
    const url = 'https://i.pximg.net/img-master/missing.jpg';

    final reported = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    ImagePreloadResult? result;
    try {
      // The worker does real IO, so the preload lives in real async.
      result = await tester.runAsync(
        () => PixivImage.preload(
          context,
          url,
          tierKey: '1:0',
          tier: IllustImageTier.large,
        ),
      );
    } finally {
      FlutterError.onError = previous;
    }

    expect(result, ImagePreloadResult.failed);
    expect(client.urls, [url]);
    expect(reported, isEmpty);
    expect(
      IllustTierCache.isRecorded('1:0', IllustImageTier.large, url),
      false,
    );
  });

  testWidgets('a preload the user asked for skips the queued prefetch', (
    tester,
  ) async {
    final client = HeldBodyClient();
    final worker = inProcessImageWorker(() => client);
    final context = await _context(tester, worker);
    const asked = 'https://i.pximg.net/img-master/asked.jpg';

    await tester.runAsync(() async {
      final preloads = [
        for (var i = 0; i <= _backgroundSlots; i++)
          PixivImage.preload(
            context,
            'https://i.pximg.net/img-master/warm$i.jpg',
          ),
        PixivImage.preload(
          context,
          asked,
          priority: ImageFetchPriority.foreground,
        ),
      ];
      // Wanted until the page it was preloaded for mounts and takes over.
      expect(worker.demand.wants(asked), isTrue);
      await pollUntil(() => client.urls.contains(asked));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Both background slots are busy and the third warm-up still waits.
      expect(client.urls, hasLength(_backgroundSlots + 1));
      await client.closeAll();
      // Freeing the background lane admits the warm-up still queued.
      await pollUntil(() => client.urls.length == _backgroundSlots + 2);
      await client.closeAll();
      await Future.wait(preloads);
    });
  });

  testWidgets('a warm-up nobody wants any more ends as dropped, without a '
      'log line or a request', (tester) async {
    final client = HeldBodyClient();
    final worker = inProcessImageWorker(() => client);
    final context = await _context(tester, worker);
    final window = Object();
    const stale = 'https://i.pximg.net/img-master/stale.jpg';
    final warm = [
      for (var i = 0; i < _backgroundSlots; i++)
        'https://i.pximg.net/img-master/busy$i.jpg',
      stale,
    ];
    final logs = <String?>[];
    final previousPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message);
    try {
      await tester.runAsync(() async {
        worker.demand.setPrefetchWindow(window, warm.toSet());
        final results = [
          for (final url in warm) PixivImage.preload(context, url),
        ];
        await pollUntil(() => client.urls.length == _backgroundSlots);
        worker.demand.clearPrefetchWindow(window);
        expect(await results.last, ImagePreloadResult.dropped);
        await client.closeAll();
        await Future.wait(results);
      });
    } finally {
      debugPrint = previousPrint;
    }
    expect(client.urls, isNot(contains(stale)));
    expect(logs.where((m) => m!.contains('stale')), isEmpty);
  });
}
