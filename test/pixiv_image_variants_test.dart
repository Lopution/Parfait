import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
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
    expect(image.fadeOutDuration, Duration.zero);
  });
}
