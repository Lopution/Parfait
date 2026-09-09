import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
import 'package:pixiv_func/app/pixiv_image.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

Widget _host(Widget child) =>
    ProviderScope(child: MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
home: Scaffold(body: child)));

int? _memCacheWidthOf(WidgetTester tester) =>
    tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .memCacheWidth;

void main() {
  installMemoryPreferences();
  test('decodeWidthFor: DPR width, capped at 1.5x logical pixels', () {
    // DPR 1 below the cap: pure logical width.
    expect(PixivImage.decodeWidthFor(200, devicePixelRatio: 1), 200);
    // DPR 2 above the cap: 200x2=400 clamps to 200x1.5=300.
    expect(PixivImage.decodeWidthFor(200, devicePixelRatio: 2), 300);
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
    // 200x3=600 clamps to the 1.5x cap -> 300.
    expect(_memCacheWidthOf(tester), 300);
  });

  testWidgets('avatar variant decodes at the avatar box size', (tester) async {
    await tester.pumpWidget(
      _host(PixivImage.avatar('https://i.pximg.net/test.jpg', size: 54)),
    );
    await tester.pump();
    // 54x3=162 clamps to 54x1.5=81.
    expect(_memCacheWidthOf(tester), 81);
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
}
