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
import 'package:parfait/core/image/worker_image_provider.dart';
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
/// legacy download (original files only) never finishes.
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

bool _painted(WidgetTester tester) => tester
    .widgetList<RawImage>(find.byType(RawImage))
    .any((image) => image.image != null);

void main() {
  setUp(
    () => PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages(),
  );

  testWidgets('a worker card frame stands in while the legacy original '
      'loads', (tester) async {
    // The card → viewer Hero: the card decoded on the worker, the viewer
    // shows the original file, still on the legacy pipeline. The card's
    // frame must cover the viewer slot until its own decode lands.
    const card = 'https://i.pximg.net/img-master/hand-off_square.jpg';
    const original = 'https://i.pximg.net/img-original/hand-off_p0.png';
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
    await pumpIoUntil(tester, () => _painted(tester));
    expect(world.workerUrls, [card]);

    final progress = ValueNotifier(const ImageLoadProgress.idle());
    addTearDown(progress.dispose);
    // A fresh element, as on the viewer route.
    await tester.pumpWidget(
      world.host(
        KeyedSubtree(
          key: UniqueKey(),
          child: PixivImage(
            url: original,
            transitionKey: 'hand-off',
            progress: progress,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(world.legacy.urls, [original]);
    expect(_painted(tester), isTrue, reason: 'the card frame stands in');
    expect(world.workerUrls, [card], reason: 'the stand-in is not refetched');
  });

  testWidgets('a detail image with progress decodes the card\'s file on the '
      'worker', (tester) async {
    // The detail page shows the card's URL uncapped, with a progress ring.
    // Both decodes are the worker's: the file the card downloaded is read
    // from disk, nothing is fetched again and the ring never shows.
    const url = 'https://i.pximg.net/img-master/shared_master.jpg';
    final world = _World();
    await tester.pumpWidget(
      world.host(
        const PixivImage(url: url, memCacheWidth: 200, transitionKey: 'same'),
      ),
    );
    await pumpIoUntil(tester, () => _painted(tester));

    final progress = ValueNotifier(const ImageLoadProgress.idle());
    addTearDown(progress.dispose);
    final reports = <ImageLoadProgress>[];
    progress.addListener(() => reports.add(progress.value));
    await tester.pumpWidget(
      world.host(
        KeyedSubtree(
          key: UniqueKey(),
          child: PixivImage(
            url: url,
            transitionKey: 'same',
            progress: progress,
          ),
        ),
      ),
    );
    expect(_painted(tester), isTrue, reason: 'the card frame stands in');
    final uncapped = WorkerImageProvider(world.worker, url);
    await pumpIoUntil(
      tester,
      () =>
          PaintingBinding.instance.imageCache.statusForKey(uncapped).keepAlive,
    );
    expect(world.workerUrls, [url]);
    expect(world.legacy.urls, isEmpty);
    expect(reports.where((report) => report.loading), isEmpty);
  });

  testWidgets('a lower tier the worker decoded underlays a legacy original '
      'without a fetch', (tester) async {
    // A viewer page with no Hero history paints the best lower tier of the
    // same page while its own tier loads. The card decoded that tier on
    // the worker, at the card's width: the underlay must be that decode,
    // not an uncapped one that would download the file again.
    const medium = 'https://i.pximg.net/img-master/underlay_medium.jpg';
    const original = 'https://i.pximg.net/img-original/underlay_p0.png';
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
    await pumpIoUntil(tester, () => _painted(tester));

    final progress = ValueNotifier(const ImageLoadProgress.idle());
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      world.host(
        KeyedSubtree(
          key: UniqueKey(),
          child: PixivImage(
            url: original,
            tierKey: 'underlay:0',
            tier: IllustImageTier.original,
            progress: progress,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_painted(tester), isTrue, reason: 'the medium tier underlays');
    expect(world.legacy.urls, [original]);
    expect(world.workerUrls, [medium]);
  });

  testWidgets('a preload lands on the pipeline of the widget that will '
      'show it', (tester) async {
    const preview = 'https://i.pximg.net/img-master/preload_square.jpg';
    const detail = 'https://i.pximg.net/img-master/preload_master.jpg';
    const original = 'https://i.pximg.net/img-original/preload_p0.png';
    final world = _World();
    await tester.pumpWidget(world.host(const SizedBox()));
    final context = tester.element(find.byType(SizedBox).last);

    final results = <ImagePreloadResult>[];
    for (final (url, width) in [(preview, 200), (detail, null)]) {
      unawaited(
        PixivImage.preload(
          context,
          url,
          cacheManager: world.legacy,
          memCacheWidth: width,
        ).then(results.add),
      );
    }
    // An original file stays legacy, as the widget would load it.
    unawaited(
      PixivImage.preload(
        context,
        original,
        cacheManager: world.legacy,
        memCacheWidth: 200,
      ),
    );
    await pumpIoUntil(tester, () => results.length == 2);
    expect(results, everyElement(ImagePreloadResult.decoded));
    expect(world.workerUrls, unorderedEquals([preview, detail]));
    expect(world.legacy.urls, [original]);

    // The warmed entry is the one the widget resolves: its first frame is
    // the image, with no placeholder and no second fetch.
    await tester.pumpWidget(
      world.host(const PixivImage(url: preview, memCacheWidth: 200)),
    );
    expect(_painted(tester), isTrue);
    expect(world.workerUrls, unorderedEquals([preview, detail]));
  });
}
