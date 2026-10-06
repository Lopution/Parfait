import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octo_image/octo_image.dart';

import 'helpers/image_network.dart';
import 'helpers/test_preferences.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/image/image_worker.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

/// These tests look at how an image is set up; nothing loads.
late ImageWorker _worker;

Widget _host(Widget child) => ProviderScope(
  overrides: [imageWorkerProvider.overrideWithValue(_worker)],
  child: MaterialApp(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh', 'CN'),
    home: Scaffold(body: child),
  ),
);

int? _legacyDecodeWidthOf(WidgetTester tester) => tester
    .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
    .memCacheWidth;

/// A capped image loads through the worker; its decode width is the
/// [ResizeImage] around the worker's provider. The width is the memory
/// contract, and nothing paints it before a frame loads.
int? _workerDecodeWidthOf(WidgetTester tester) {
  expect(find.byType(CachedNetworkImage), findsNothing);
  final image = tester.widget<OctoImage>(find.byType(OctoImage)).image;
  return (image as ResizeImage).width;
}

/// The fades of the image on screen, on whichever pipeline it loads. The
/// fade is the contract here; it only becomes visible once a frame loads.
(Duration? fadeIn, Duration? fadeOut) _fadesOf(WidgetTester tester) {
  final legacy = find.byType(CachedNetworkImage);
  if (legacy.evaluate().isNotEmpty) {
    final image = tester.widget<CachedNetworkImage>(legacy);
    return (image.fadeInDuration, image.fadeOutDuration);
  }
  final image = tester.widget<OctoImage>(find.byType(OctoImage));
  return (image.fadeInDuration, image.fadeOutDuration);
}

/// An uncapped image stays on the legacy pipeline; a capped one moves to
/// the worker. Slot and fade policy must not depend on which.
const _pipelines = [('legacy', null), ('worker', 300)];

void main() {
  installMemoryPreferences();
  setUp(() => _worker = stalledImageWorker());
  test('decodeWidthFor: decodes at the physical display width', () {
    // The decode target is layout x DPR — capping it at 1.5x *logical* pixels
    // decoded high-DPR devices at half resolution and upscaled them (the
    // blurry/jagged thumbnail regression).
    expect(PixivImage.decodeWidthFor(200, devicePixelRatio: 1), 200);
    expect(PixivImage.decodeWidthFor(200, devicePixelRatio: 2), 400);
    expect(PixivImage.decodeWidthFor(200, devicePixelRatio: 3), 600);
    // Tiny boxes never decode below 1px.
    expect(PixivImage.decodeWidthFor(0.1, devicePixelRatio: 2), 1);
  });

  testWidgets('feed variant decodes at layout width under the test DPR', (
    tester,
  ) async {
    // flutter_test default view: DPR 3, 800x600 logical.
    await tester.pumpWidget(
      _host(PixivImage.feed('https://i.pximg.net/test.jpg', layoutWidth: 200)),
    );
    await tester.pump();
    // 200 logical at DPR 3 -> 600 physical decode.
    expect(_workerDecodeWidthOf(tester), 600);
  });

  testWidgets('avatar variant decodes at the avatar box size', (tester) async {
    await tester.pumpWidget(
      _host(PixivImage.avatar('https://i.pximg.net/test.jpg', size: 54)),
    );
    await tester.pump();
    // 54 logical at DPR 3 -> 162 physical decode.
    expect(_workerDecodeWidthOf(tester), 162);
  });

  testWidgets('detail variant decodes at the screen width', (tester) async {
    await tester.pumpWidget(
      _host(PixivImage.detail('https://i.pximg.net/test.jpg')),
    );
    await tester.pump();
    // Test view is 800 logical wide at DPR 3.
    expect(_workerDecodeWidthOf(tester), 800 * 3);
  });

  testWidgets('plain (viewer) variant has no decode cap', (tester) async {
    await tester.pumpWidget(
      _host(const PixivImage(url: 'https://i.pximg.net/test.jpg')),
    );
    await tester.pump();

    expect(_legacyDecodeWidthOf(tester), isNull);
  });

  testWidgets(
    'loose-constrained detail fills the bounded width, not intrinsic size',
    (tester) async {
      // The detail Stack gives children loose constraints: without an
      // explicit width the Image sized itself to decoded pixels, so a
      // card-width hero decode landed small with blank space beside it.
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 320,
            child: Stack(
              children: [PixivImage(url: 'https://i.pximg.net/test.jpg')],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .width,
        320,
      );
    },
  );

  testWidgets('unbounded width keeps intrinsic sizing', (tester) async {
    await tester.pumpWidget(
      _host(
        const SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: PixivImage(url: 'https://i.pximg.net/test.jpg'),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage)).width,
      isNull,
    );
  });

  testWidgets('quality handoff keeps an old decoded frame placeholder', (
    tester,
  ) async {
    const key = 'pixiv-image-transition-test';
    await tester.pumpWidget(
      _host(
        PixivImage(
          key: const ValueKey(key),
          url: 'https://i.pximg.net/old.jpg',
          transitionKey: key,
          memCacheWidth: 300,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      _host(
        PixivImage(
          key: const ValueKey(key),
          url: 'https://i.pximg.net/new.jpg',
          transitionKey: key,
          memCacheWidth: 900,
        ),
      ),
    );
    await tester.pump();

    final image = tester.widget<OctoImage>(find.byType(OctoImage));
    expect(image.gaplessPlayback, isTrue);
    // A URL swap on a live element is a slot hand-off regardless of
    // whether the previous frame resolved — Glide replaces instantly on a
    // live target and never replays the load transition.
    expect(image.fadeOutDuration, Duration.zero);
    expect(image.fadeInDuration, Duration.zero);
  });

  for (final (pipeline, width) in _pipelines) {
    group(pipeline, () {
      testWidgets('a recycled slot swapping to another work never '
          'crossfades', (tester) async {
        // Feed lists reuse card elements by position; pull-to-refresh can
        // land a different work on the same element. The swap must be
        // instant — fading work B in over retained work A reads as a
        // cross-work dissolve on every refreshed slot.
        await tester.pumpWidget(
          _host(
            PixivImage(
              url: 'https://i.pximg.net/work-a.jpg',
              memCacheWidth: width,
            ),
          ),
        );
        await tester.pump();
        await tester.pumpWidget(
          _host(
            PixivImage(
              url: 'https://i.pximg.net/work-b.jpg',
              memCacheWidth: width,
            ),
          ),
        );
        await tester.pump();

        expect(_fadesOf(tester), (Duration.zero, Duration.zero));
      });

      testWidgets('the same URL on a reused slot keeps the cold-load fade', (
        tester,
      ) async {
        // Same work re-landing on the same element (e.g. the identical feed
        // after refresh) is not a hand-off: nothing changed visually, so
        // the ordinary fade policy still applies.
        for (var i = 0; i < 2; i++) {
          await tester.pumpWidget(
            _host(
              PixivImage(
                url: 'https://i.pximg.net/work-a.jpg',
                memCacheWidth: width,
              ),
            ),
          );
          await tester.pump();
        }

        expect(_fadesOf(tester), (
          MotionTokens.imageFade,
          MotionTokens.imageFadeOut,
        ));
      });

      testWidgets('a freshly created slot keeps the cold-load fade', (
        tester,
      ) async {
        // A new element has no previous URL at all — the genuine cold load.
        await tester.pumpWidget(
          _host(
            PixivImage(
              url: 'https://i.pximg.net/work-a.jpg',
              memCacheWidth: width,
            ),
          ),
        );
        await tester.pump();

        expect(_fadesOf(tester), (
          MotionTokens.imageFade,
          MotionTokens.imageFadeOut,
        ));
      });
    });
  }

  group('ticker mode flips', () {
    /// [image] under a TickerMode driven by [tickers]; the image widget is
    /// const, so only the image's own reaction can rebuild it.
    Widget frozenBy(ValueNotifier<bool> tickers, Widget image) => _host(
      ValueListenableBuilder<bool>(
        valueListenable: tickers,
        builder: (_, enabled, child) =>
            TickerMode(enabled: enabled, child: child!),
        child: image,
      ),
    );

    CachedNetworkImage image(WidgetTester tester) =>
        tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));

    testWidgets('a cold load in flight disarms and rearms its fade', (
      tester,
    ) async {
      final tickers = ValueNotifier(true);
      addTearDown(tickers.dispose);
      await tester.pumpWidget(
        frozenBy(
          tickers,
          const PixivImage(url: 'https://i.pximg.net/cold-flip.jpg'),
        ),
      );
      expect(image(tester).fadeInDuration, MotionTokens.imageFade);

      // A transition starts: the snapshot must not bake a half fade.
      tickers.value = false;
      await tester.pump();
      expect(image(tester).fadeInDuration, Duration.zero);

      tickers.value = true;
      await tester.pump();
      expect(image(tester).fadeInDuration, MotionTokens.imageFade);
    });

    testWidgets('an image the flip cannot change is not rebuilt', (
      tester,
    ) async {
      // Every image on a page used to rebuild in the frame a transition
      // started or ended — the layout spikes on device.
      final tickers = ValueNotifier(true);
      addTearDown(tickers.dispose);
      await tester.pumpWidget(
        frozenBy(
          tickers,
          const PixivImage(
            url: 'https://i.pximg.net/no-fade-flip.jpg',
            fade: false,
          ),
        ),
      );
      final before = image(tester);

      tickers.value = false;
      await tester.pump();
      tickers.value = true;
      await tester.pump();
      expect(image(tester), same(before));
    });
  });

  testWidgets('an image on screen holds its URL in the image demand', (
    tester,
  ) async {
    const a = 'https://i.pximg.net/hold-a.jpg';
    const b = 'https://i.pximg.net/hold-b.jpg';
    Widget images(List<String> urls) => _host(
      Column(
        children: [
          for (final url in urls)
            SizedBox(height: 50, child: PixivImage(url: url)),
        ],
      ),
    );
    await tester.pumpWidget(images([a, a]));
    final demand = ProviderScope.containerOf(
      tester.element(find.byType(PixivImage).first),
    ).read(pixivNetworkFactoryProvider).imageDemand;
    expect(demand.debugHolds(a), 2);

    // The second slot switches work: its hold moves with it.
    await tester.pumpWidget(images([a, b]));
    expect(demand.debugHolds(a), 1);
    expect(demand.debugHolds(b), 1);

    await tester.pumpWidget(images([]));
    expect(demand.debugHolds(a), 0);
    expect(demand.debugHolds(b), 0);
    // Just released: still wanted for the grace period.
    expect(demand.wants(b), isTrue);
  });

  testWidgets('a worker image holds its URL in the worker\'s demand', (
    tester,
  ) async {
    const url = 'https://i.pximg.net/hold-worker.jpg';
    Widget images(int count) => _host(
      Column(
        children: [
          for (var i = 0; i < count; i++)
            const SizedBox(
              height: 50,
              child: PixivImage(url: url, memCacheWidth: 300),
            ),
        ],
      ),
    );
    await tester.pumpWidget(images(2));
    // The worker's demand drives its cancels; the legacy one never sees
    // the URL.
    final legacy = ProviderScope.containerOf(
      tester.element(find.byType(PixivImage).first),
    ).read(pixivNetworkFactoryProvider).imageDemand;
    expect(_worker.demand.debugHolds(url), 2);
    expect(legacy.debugHolds(url), 0);

    await tester.pumpWidget(images(0));
    expect(_worker.demand.debugHolds(url), 0);
  });
}
