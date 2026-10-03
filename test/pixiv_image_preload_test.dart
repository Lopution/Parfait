import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/image_tier_cache.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/network/compat/image_cache.dart';

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

    await tester.runAsync(() async {
      final manager = testImageCacheManager(
        PriorityFileService(httpClient: client),
      );
      for (var i = 0; i <= PriorityFileService.backgroundSlots; i++) {
        unawaited(
          PixivImage.preload(
            context,
            'https://i.pximg.net/img-master/warm$i.jpg',
            cacheManager: manager,
          ),
        );
      }
      unawaited(
        PixivImage.preload(
          context,
          asked,
          cacheManager: manager,
          priority: ImageFetchPriority.foreground,
        ),
      );
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
    });
  });
}
