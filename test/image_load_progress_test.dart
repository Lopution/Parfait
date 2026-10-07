import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/illust_fixtures.dart';
import 'helpers/image_network.dart';
import 'helpers/detail_world.dart';

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

/// A worker transfer the test feeds by hand: [_url]'s body arrives as the
/// test adds it, declared at [total] bytes; any other URL never answers.
class _Transfer {
  _Transfer({required this.total});

  final int total;
  final body = StreamController<List<int>>();
  late final client = HeldBodyClient(
    respond: (request) => '${request.url}' == _url
        ? http.StreamedResponse(
            body.stream,
            200,
            contentLength: total,
            request: request,
          )
        : null,
  );
  late final worker = inProcessImageWorker(() => client);

  bool get requested => client.urls.contains(_url);

  List<Override> get overrides => [
    pixivNetworkFactoryProvider.overrideWithValue(
      ScriptedImageNetwork(
        ScriptedCacheManager((_) => StreamController<FileResponse>().stream),
      ),
    ),
    imageWorkerProvider.overrideWithValue(worker),
  ];
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
    final transfer = _Transfer(total: onePixelPng.length);
    final progress = ValueNotifier(const ImageLoadProgress.idle());
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: transfer.overrides,
        child: _app(PixivImage(url: _url, progress: progress)),
      ),
    );
    await pumpIoUntil(tester, () => transfer.requested);
    expect(progress.value, const ImageLoadProgress.idle());

    final head = onePixelPng.length * 2 ~/ 5;
    transfer.body.add(onePixelPng.sublist(0, head));
    await pumpIoUntil(tester, () => progress.value.loading);
    expect(progress.value, ImageLoadProgress.ofBytes(head, onePixelPng.length));

    transfer.body.add(onePixelPng.sublist(head));
    unawaited(transfer.body.close());
    await pumpIoUntil(tester, () => !progress.value.loading);
    expect(progress.value, const ImageLoadProgress.idle());
  });

  testWidgets('a new URL does not inherit the old download\'s progress', (
    tester,
  ) async {
    // The second URL's transfer never starts.
    final transfer = _Transfer(total: 1000);
    final progress = ValueNotifier(const ImageLoadProgress.idle());
    addTearDown(progress.dispose);
    Widget image(String url) => ProviderScope(
      overrides: transfer.overrides,
      child: _app(PixivImage(url: url, progress: progress)),
    );
    await tester.pumpWidget(image(_url));
    await pumpIoUntil(tester, () => transfer.requested);
    transfer.body.add(List.filled(700, 0));
    await pumpIoUntil(tester, () => progress.value.loading);
    expect(progress.value, const ImageLoadProgress.loading(0.7));

    await tester.pumpWidget(image('$_url?next'));
    await tester.pump();
    expect(progress.value, const ImageLoadProgress.idle());
    await unmountPastReleaseGrace(tester);
  });

  group('detail page', () {
    Future<void> pumpPage(
      WidgetTester tester, {
      required String? detailUrl,
    }) async {
      final transfer = _Transfer(total: 1000);
      final (container, _, _) = await makeWorld(
        extraOverrides: transfer.overrides,
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
      await pumpIoUntil(tester, () => transfer.requested);
      transfer.body.add(List.filled(100, 0));
      if (detailUrl != null) {
        await pumpIoUntil(
          tester,
          () => tester
              .widget<ImageLoadProgressOverlay>(
                find.byType(ImageLoadProgressOverlay),
              )
              .progress
              .value
              .loading,
        );
      } else {
        await _settle(tester);
      }
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('the settled detail image shows the ring', (tester) async {
      await pumpPage(tester, detailUrl: _url);
      expect(_ring, findsOneWidget);
      await unmountPastReleaseGrace(tester);
    });

    testWidgets('the Hero-phase preview does not', (tester) async {
      await pumpPage(tester, detailUrl: null);
      expect(_ring, findsNothing);
      await unmountPastReleaseGrace(tester);
    });
  });
}
