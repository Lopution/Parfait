import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/illust_fixtures.dart';
import 'helpers/image_network.dart';
import 'illust_detail_page_test.dart' show makeWorld;

const _url = 'https://i.pximg.net/img-master/progress.jpg';

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: appLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  home: child,
);

Finder get _ring => find.byType(CircularProgressIndicator);

/// Lets real IO and image decoding finish, then flushes frames.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

/// A download the test feeds by hand: progress events, then the file.
class _Download {
  final controller = StreamController<FileResponse>();
  late final manager = ScriptedCacheManager((_) => controller.stream);

  void progress(int downloaded, int total) =>
      controller.add(DownloadProgress(_url, total, downloaded));
}

void main() {
  setUp(
    () => PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages(),
  );

  group('overlay', () {
    testWidgets('a load shorter than the delay never shows the ring', (
      tester,
    ) async {
      final progress = ValueNotifier(const ImageLoadProgress.idle());
      addTearDown(progress.dispose);
      await tester.pumpWidget(
        _app(ImageLoadProgressOverlay(progress: progress)),
      );
      progress.value = const ImageLoadProgress.loading(0.2);
      await tester.pump(const Duration(milliseconds: 250));
      expect(_ring, findsNothing);
      progress.value = const ImageLoadProgress.idle();
      await tester.pump(const Duration(seconds: 1));
      expect(_ring, findsNothing);
    });

    testWidgets('a slow load shows its percentage, then the ring goes', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final progress = ValueNotifier(const ImageLoadProgress.idle());
      addTearDown(progress.dispose);
      await tester.pumpWidget(
        _app(ImageLoadProgressOverlay(progress: progress)),
      );
      progress.value = const ImageLoadProgress.loading();
      await tester.pump(const Duration(milliseconds: 290));
      expect(_ring, findsNothing);
      await tester.pump(const Duration(milliseconds: 20));
      expect(_ring, findsOneWidget);
      expect(tester.widget<CircularProgressIndicator>(_ring).value, isNull);

      progress.value = const ImageLoadProgress.loading(0.5);
      // Past the fade-in: a transparent ring is left out of semantics.
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSemantics(find.bySemanticsLabel('图片加载中')).value, '50%');

      progress.value = const ImageLoadProgress.idle();
      await tester.pumpAndSettle();
      expect(_ring, findsNothing);
      semantics.dispose();
    });

    testWidgets('taps pass through the ring', (tester) async {
      final progress = ValueNotifier(const ImageLoadProgress.loading());
      addTearDown(progress.dispose);
      var taps = 0;
      await tester.pumpWidget(
        _app(
          Stack(
            children: [
              Positioned.fill(child: GestureDetector(onTap: () => taps++)),
              Positioned.fill(
                child: ImageLoadProgressOverlay(progress: progress),
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(_ring, findsOneWidget);
      await tester.tap(_ring, warnIfMissed: false);
      expect(taps, 1);
    });
  });

  testWidgets('PixivImage reports the download it is painting', (tester) async {
    final file = await onePixelPngDownload(tester, _url);
    final download = _Download();
    final progress = ValueNotifier(const ImageLoadProgress.idle());
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pixivNetworkFactoryProvider.overrideWithValue(
            ScriptedImageNetwork(download.manager),
          ),
        ],
        child: _app(PixivImage(url: _url, progress: progress)),
      ),
    );
    await tester.pump();
    expect(progress.value, const ImageLoadProgress.idle());

    download.progress(400, 1000);
    await tester.pump();
    expect(progress.value, const ImageLoadProgress.loading(0.4));

    download.controller.add(file);
    unawaited(download.controller.close());
    for (var i = 0; i < 20 && progress.value.loading; i++) {
      await _settle(tester);
    }
    expect(progress.value, const ImageLoadProgress.idle());
  });

  testWidgets('a new URL does not inherit the old download\'s progress', (
    tester,
  ) async {
    final first = StreamController<FileResponse>();
    // The second URL's download never starts.
    final network = ScriptedImageNetwork(
      ScriptedCacheManager(
        (attempt) => attempt == 1
            ? first.stream
            : StreamController<FileResponse>().stream,
      ),
    );
    final progress = ValueNotifier(const ImageLoadProgress.idle());
    addTearDown(progress.dispose);
    Widget image(String url) => ProviderScope(
      overrides: [pixivNetworkFactoryProvider.overrideWithValue(network)],
      child: _app(PixivImage(url: url, progress: progress)),
    );
    await tester.pumpWidget(image(_url));
    await tester.pump();
    first.add(const DownloadProgress(_url, 1000, 700));
    await tester.pump();
    expect(progress.value, const ImageLoadProgress.loading(0.7));

    await tester.pumpWidget(image('$_url?next'));
    await tester.pump();
    expect(progress.value, const ImageLoadProgress.idle());
  });

  group('detail page', () {
    Future<_Download> pumpPage(
      WidgetTester tester, {
      required String? detailUrl,
    }) async {
      final download = _Download();
      final (container, _, _) = await makeWorld(
        extraOverrides: [
          pixivNetworkFactoryProvider.overrideWithValue(
            ScriptedImageNetwork(download.manager),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(
            SingleChildScrollView(
              child: DetailPageImage(
                entity: parseIllust(illustJson(42)),
                index: 0,
                heroTag: 'hero-42',
                heroScope: 'feed',
                heroImageUrl: _url,
                detailUrl: detailUrl,
                downloadMode: false,
                selected: false,
                onToggleSelect: () {},
                onLongPress: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      download.progress(100, 1000);
      await tester.pump(const Duration(seconds: 1));
      return download;
    }

    testWidgets('the settled detail image shows the ring', (tester) async {
      await pumpPage(tester, detailUrl: _url);
      expect(_ring, findsOneWidget);
    });

    testWidgets('the Hero-phase preview does not', (tester) async {
      await pumpPage(tester, detailUrl: null);
      expect(_ring, findsNothing);
    });
  });
}
