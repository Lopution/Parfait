import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/network/compat/network_providers.dart';

import 'helpers/image_network.dart';

/// A legacy download that never finishes; [urls] records each request.
class _PendingCacheManager extends ScriptedCacheManager {
  _PendingCacheManager()
    : super((_) => StreamController<FileResponse>().stream);

  final urls = <String>[];

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    urls.add(url);
    return super.getFileStream(url, withProgress: withProgress);
  }
}

/// Both pipelines in one scope: the worker serves a PNG for every URL, the
/// legacy download never finishes.
class _World {
  final workerUrls = <String>[];
  final legacy = _PendingCacheManager();
  late final worker = inProcessImageWorker(
    () => MockClient((request) async {
      workerUrls.add('${request.url}');
      return http.Response.bytes(onePixelPng, 200);
    }),
  );

  Widget host(Widget child) => ProviderScope(
    overrides: [
      pixivNetworkFactoryProvider.overrideWithValue(
        ScriptedImageNetwork(legacy),
      ),
      imageWorkerProvider.overrideWithValue(worker),
    ],
    child: MaterialApp(
      home: Center(child: SizedBox.square(dimension: 200, child: child)),
    ),
  );
}

/// Real IO turns between pumps until [done] (the worker's hops each need
/// one), failing after a bound.
Future<void> _settleUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 60 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'settled within the bound');
}

bool _painted(WidgetTester tester) => tester
    .widgetList<RawImage>(find.byType(RawImage))
    .any((image) => image.image != null);

void main() {
  setUp(
    () => PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages(),
  );

  testWidgets('a worker card frame stands in while the legacy detail image '
      'loads', (tester) async {
    // The card → detail Hero: the card decoded on the worker, the detail
    // image reports progress and loads on the legacy pipeline. The card's
    // frame must cover the detail slot until its own decode lands.
    const card = 'https://i.pximg.net/img-master/hand-off_square.jpg';
    const detail = 'https://i.pximg.net/img-master/hand-off_master.jpg';
    final world = _World();
    await tester.pumpWidget(
      world.host(
        const PixivImage(
          url: card,
          memCacheWidth: 200,
          transitionKey: 'hand-off',
        ),
      ),
    );
    await _settleUntil(tester, () => _painted(tester));
    expect(world.workerUrls, [card]);

    final progress = ValueNotifier(const ImageLoadProgress.idle());
    addTearDown(progress.dispose);
    // A fresh element, as on the detail route.
    await tester.pumpWidget(
      world.host(
        KeyedSubtree(
          key: UniqueKey(),
          child: PixivImage(
            url: detail,
            transitionKey: 'hand-off',
            progress: progress,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(world.legacy.urls, [detail]);
    expect(_painted(tester), isTrue, reason: 'the card frame stands in');
    expect(world.workerUrls, [card], reason: 'the stand-in is not refetched');
  });

  testWidgets('a legacy request for a URL the worker decoded does not hide '
      'the worker frame', (tester) async {
    // A tier record says the tier decoded, not where. The detail image
    // (legacy) of the card's own URL must not count as decoded because the
    // card recorded the tier — a later hand-off would pick it as the
    // stand-in and wait on its download instead of the card's frame.
    const card = 'https://i.pximg.net/img-master/record_medium.jpg';
    const next = 'https://i.pximg.net/img-master/record_large.jpg';
    final world = _World();
    final progress = ValueNotifier(const ImageLoadProgress.idle());
    addTearDown(progress.dispose);
    Widget fresh(PixivImage image) =>
        world.host(KeyedSubtree(key: UniqueKey(), child: image));
    await tester.pumpWidget(
      fresh(
        const PixivImage(
          url: card,
          memCacheWidth: 200,
          transitionKey: 'record',
          tierKey: 'record:0',
          tier: IllustImageTier.medium,
        ),
      ),
    );
    await _settleUntil(tester, () => _painted(tester));
    await tester.pumpWidget(
      fresh(
        PixivImage(
          url: card,
          transitionKey: 'record',
          tierKey: 'record:0',
          tier: IllustImageTier.medium,
          progress: progress,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      fresh(PixivImage(url: next, transitionKey: 'record', progress: progress)),
    );
    await tester.pump();
    expect(world.legacy.urls, [card, next]);
    expect(_painted(tester), isTrue, reason: 'the card frame stands in');
  });

  testWidgets('a lower tier the worker decoded underlays a legacy viewer '
      'page without a fetch', (tester) async {
    // A viewer page with no Hero history paints the best lower tier of the
    // same page while its own tier loads. The card decoded that tier on
    // the worker, at the card's width: the underlay must be that decode,
    // not an uncapped legacy one that would download the file again.
    const medium = 'https://i.pximg.net/img-master/underlay_medium.jpg';
    const large = 'https://i.pximg.net/img-master/underlay_large.jpg';
    final world = _World();
    await tester.pumpWidget(
      world.host(
        const PixivImage(
          url: medium,
          memCacheWidth: 200,
          tierKey: 'underlay:0',
          tier: IllustImageTier.medium,
        ),
      ),
    );
    await _settleUntil(tester, () => _painted(tester));

    final progress = ValueNotifier(const ImageLoadProgress.idle());
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      world.host(
        KeyedSubtree(
          key: UniqueKey(),
          child: PixivImage(
            url: large,
            tierKey: 'underlay:0',
            tier: IllustImageTier.large,
            progress: progress,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_painted(tester), isTrue, reason: 'the medium tier underlays');
    expect(world.legacy.urls, [large]);
    expect(world.workerUrls, [medium]);
  });

  testWidgets('a preload lands on the pipeline of the widget that will '
      'show it', (tester) async {
    const preview = 'https://i.pximg.net/img-master/preload_square.jpg';
    const detail = 'https://i.pximg.net/img-master/preload_master.jpg';
    final world = _World();
    await tester.pumpWidget(world.host(const SizedBox()));
    final context = tester.element(find.byType(SizedBox).last);

    final previewDone = PixivImage.preload(
      context,
      preview,
      memCacheWidth: 200,
    );
    // The detail page shows progress, so it stays legacy.
    unawaited(
      PixivImage.preload(
        context,
        detail,
        cacheManager: world.legacy,
        memCacheWidth: 200,
        useWorker: false,
      ),
    );
    // An original file and an uncapped decode stay legacy, as the widget
    // would load them.
    const original = 'https://i.pximg.net/img-original/preload_p0.png';
    const uncapped = 'https://i.pximg.net/img-master/preload_uncapped.jpg';
    unawaited(
      PixivImage.preload(
        context,
        original,
        cacheManager: world.legacy,
        memCacheWidth: 200,
      ),
    );
    unawaited(
      PixivImage.preload(context, uncapped, cacheManager: world.legacy),
    );
    var previewResult = ImagePreloadResult.failed;
    unawaited(previewDone.then((result) => previewResult = result));
    await _settleUntil(
      tester,
      () => previewResult == ImagePreloadResult.decoded,
    );
    expect(world.workerUrls, [preview]);
    expect(world.legacy.urls, unorderedEquals([detail, original, uncapped]));

    // The warmed entry is the one the widget resolves: its first frame is
    // the image, with no placeholder and no second fetch.
    await tester.pumpWidget(
      world.host(const PixivImage(url: preview, memCacheWidth: 200)),
    );
    expect(_painted(tester), isTrue);
    expect(world.workerUrls, [preview]);
  });
}
