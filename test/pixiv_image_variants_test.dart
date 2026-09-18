import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
import 'package:pixiv_func/app/motion/motion_tokens.dart';
import 'package:pixiv_func/app/pixiv_image.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

Widget _host(Widget child) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh', 'CN'),
    home: Scaffold(body: child),
  ),
);

int? _memCacheWidthOf(WidgetTester tester) => tester
    .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
    .memCacheWidth;

void main() {
  installMemoryPreferences();
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
    expect(_memCacheWidthOf(tester), 600);
  });

  testWidgets('avatar variant decodes at the avatar box size', (tester) async {
    await tester.pumpWidget(
      _host(PixivImage.avatar('https://i.pximg.net/test.jpg', size: 54)),
    );
    await tester.pump();
    // 54 logical at DPR 3 -> 162 physical decode.
    expect(_memCacheWidthOf(tester), 162);
  });

  testWidgets('detail variant decodes at the screen width', (tester) async {
    await tester.pumpWidget(
      _host(PixivImage.detail('https://i.pximg.net/test.jpg')),
    );
    await tester.pump();
    // Test view is 800 logical wide at DPR 3.
    expect(_memCacheWidthOf(tester), 800 * 3);
  });

  testWidgets('plain (viewer) variant has no decode cap', (tester) async {
    await tester.pumpWidget(
      _host(const PixivImage(url: 'https://i.pximg.net/test.jpg')),
    );
    await tester.pump();

    expect(_memCacheWidthOf(tester), isNull);
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

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.useOldImageOnUrlChange, isTrue);
    // A URL swap on a live element is a slot hand-off regardless of
    // whether the previous frame resolved — Glide replaces instantly on a
    // live target and never replays the load transition.
    expect(image.fadeOutDuration, Duration.zero);
    expect(image.fadeInDuration, Duration.zero);
  });

  testWidgets('a recycled slot swapping to another work never crossfades', (
    tester,
  ) async {
    // Feed lists reuse card elements by position; pull-to-refresh can land
    // a different work on the same element. The swap must be instant —
    // fading work B in over retained work A reads as a cross-work dissolve
    // on every refreshed slot.
    await tester.pumpWidget(
      _host(const PixivImage(url: 'https://i.pximg.net/work-a.jpg')),
    );
    await tester.pump();
    await tester.pumpWidget(
      _host(const PixivImage(url: 'https://i.pximg.net/work-b.jpg')),
    );
    await tester.pump();

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.fadeInDuration, Duration.zero);
    expect(image.fadeOutDuration, Duration.zero);
  });

  testWidgets('the same URL on a reused slot keeps the cold-load fade', (
    tester,
  ) async {
    // Same work re-landing on the same element (e.g. the identical feed
    // after refresh) is not a hand-off: nothing changed visually, so the
    // ordinary fade policy still applies.
    await tester.pumpWidget(
      _host(const PixivImage(url: 'https://i.pximg.net/work-a.jpg')),
    );
    await tester.pump();
    await tester.pumpWidget(
      _host(const PixivImage(url: 'https://i.pximg.net/work-a.jpg')),
    );
    await tester.pump();

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.fadeInDuration, MotionTokens.imageFade);
    expect(image.fadeOutDuration, MotionTokens.imageFadeOut);
  });

  testWidgets('a freshly created slot keeps the cold-load fade', (
    tester,
  ) async {
    // A new element has no previous URL at all — the genuine cold load.
    await tester.pumpWidget(
      _host(const PixivImage(url: 'https://i.pximg.net/work-a.jpg')),
    );
    await tester.pump();

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.fadeInDuration, MotionTokens.imageFade);
    expect(image.fadeOutDuration, MotionTokens.imageFadeOut);
  });
}
