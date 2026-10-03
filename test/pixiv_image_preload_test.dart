import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/image_tier_cache.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/network/compat/image_cache.dart';
import 'package:parfait/core/network/compat/image_demand.dart';

import 'helpers/image_network.dart';

/// Pumps a bare host and returns a context [PixivImage.preload] can use.
Future<BuildContext> _context(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    Builder(
      builder: (c) {
        context = c;
        return const SizedBox();
      },
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
    final context = await _context(tester);
    const url = 'https://i.pximg.net/img-master/missing.jpg';

    final reported = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    try {
      // The cache manager does real disk IO, so it lives in real async.
      await tester.runAsync(
        () => PixivImage.preload(
          context,
          url,
          cacheManager: testImageCacheManager(
            PriorityFileService(httpClient: client),
          ),
          tierKey: '1:0',
          tier: IllustImageTier.large,
        ),
      );
    } finally {
      FlutterError.onError = previous;
    }

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
    final context = await _context(tester);
    const asked = 'https://i.pximg.net/img-master/asked.jpg';

    var now = DateTime(2026, 10, 3);
    final demand = ImageDemand(clock: () => now);

    await tester.runAsync(() async {
      final manager = testImageCacheManager(
        PriorityFileService(httpClient: client),
      );
      final preloads = [
        for (var i = 0; i <= PriorityFileService.backgroundSlots; i++)
          PixivImage.preload(
            context,
            'https://i.pximg.net/img-master/warm$i.jpg',
            cacheManager: manager,
          ),
        PixivImage.preload(
          context,
          asked,
          cacheManager: manager,
          demand: demand,
          priority: ImageFetchPriority.foreground,
        ),
      ];
      // Wanted until the page it was preloaded for mounts and takes over.
      now = now.add(const Duration(seconds: 9));
      expect(demand.wants(asked), isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(demand.wants(asked), isFalse);
      await pollUntil(() => client.urls.contains(asked));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Both background slots are busy and the third warm-up still waits.
      expect(client.urls, hasLength(PriorityFileService.backgroundSlots + 1));
      await client.closeAll();
      // Freeing the background lane admits the warm-up still queued.
      await pollUntil(
        () => client.urls.length == PriorityFileService.backgroundSlots + 2,
      );
      await client.closeAll();
      // No cache write may outlive the test's temp directory.
      await Future.wait(preloads);
    });
  });

  testWidgets('a warm-up nobody wants any more ends as dropped, without a '
      'log line or a request', (tester) async {
    final client = HeldBodyClient();
    final context = await _context(tester);
    final demand = ImageDemand();
    final window = Object();
    const stale = 'https://i.pximg.net/img-master/stale.jpg';
    final warm = [
      for (var i = 0; i < PriorityFileService.backgroundSlots; i++)
        'https://i.pximg.net/img-master/busy$i.jpg',
      stale,
    ];
    final logs = <String?>[];
    final previousPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message);
    try {
      await tester.runAsync(() async {
        final manager = testImageCacheManager(
          PriorityFileService(httpClient: client, demand: demand),
        );
        demand.setPrefetchWindow(window, warm.toSet());
        final results = [
          for (final url in warm)
            PixivImage.preload(
              context,
              url,
              cacheManager: manager,
              demand: demand,
            ),
        ];
        await pollUntil(
          () => client.urls.length == PriorityFileService.backgroundSlots,
        );
        demand.clearPrefetchWindow(window);
        await client.closeAll();
        expect(await results.last, ImagePreloadResult.dropped);
        await Future.wait(results);
      });
    } finally {
      debugPrint = previousPrint;
    }
    expect(client.urls, isNot(contains(stale)));
    expect(logs.where((m) => m!.contains('stale')), isEmpty);
  });
}
