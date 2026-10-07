import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/image_network.dart';

/// One URL per kind of image: an uncapped decode is recorded app-wide, and
/// a capped request for a URL with one paints that instead.
const _cappedUrl = 'https://i.pximg.net/img-master/retry-capped.jpg';
const _originalUrl = 'https://i.pximg.net/img-original/retry-original.png';

/// What the network does on one attempt.
enum _Outcome { transient, notFound, image }

/// The worker's network behind one script. The retry policy above it is
/// the same for a capped image and an original fetched in ranges (the
/// script answers a range request with the whole file), so every test runs
/// on each.
class _Pipeline {
  _Pipeline(this.name, this.image);

  final String name;
  final PixivImage image;
  _Outcome Function(int attempt) script = (_) => _Outcome.image;
  var requests = 0;

  List<Override> overrides() {
    final worker = inProcessImageWorker(
      () => MockClient((_) async {
        requests++;
        return switch (script(requests)) {
          _Outcome.transient => throw const SocketException('connection reset'),
          _Outcome.notFound => http.Response('', 404),
          _Outcome.image => http.Response.bytes(onePixelPng, 200),
        };
      }),
    );
    return [
      pixivNetworkFactoryProvider.overrideWithValue(
        ScriptedImageNetwork(
          ScriptedCacheManager((_) => fail('an image reached legacy')),
        ),
      ),
      imageWorkerProvider.overrideWithValue(worker),
    ];
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Pipeline pipeline, {
  double size = 200,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: pipeline.overrides(),
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Center(
          child: SizedBox.square(dimension: size, child: pipeline.image),
        ),
      ),
    ),
  );
  await _settle(tester);
}

/// Lets real IO and image decoding finish, then flushes frames. The
/// worker's hops (handshake, disk lookup, fetch, commit, result) each need
/// a real turn and a pump.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

bool _painted(WidgetTester tester) => tester
    .widgetList<RawImage>(find.byType(RawImage))
    .any((image) => image.image != null);

void main() {
  // Each test resolves the same URL; a decoded or errored entry left in the
  // image cache would answer without asking the network.
  setUp(
    () => PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages(),
  );

  for (final pipeline in <_Pipeline Function()>[
    () => _Pipeline(
      'capped',
      const PixivImage(url: _cappedUrl, memCacheWidth: 200),
    ),
    () => _Pipeline('original', const PixivImage(url: _originalUrl)),
  ]) {
    group(pipeline().name, () {
      testWidgets('a transient failure retries after 1 s and 3 s and then '
          'shows the image', (tester) async {
        final network = pipeline()
          ..script = (attempt) =>
              attempt < 3 ? _Outcome.transient : _Outcome.image;
        await _pump(tester, network);
        expect(network.requests, 1);
        expect(find.byIcon(Icons.broken_image), findsOneWidget);
        expect(find.byIcon(Icons.refresh), findsNothing);

        await tester.pump(const Duration(milliseconds: 900));
        expect(network.requests, 1);
        await tester.pump(const Duration(milliseconds: 100));
        await _settle(tester);
        expect(network.requests, 2);

        await tester.pump(const Duration(seconds: 3));
        await _settle(tester);
        expect(network.requests, 3);
        // Reading the file and decoding it are real IO.
        for (var i = 0; i < 20 && !_painted(tester); i++) {
          await _settle(tester);
        }
        expect(_painted(tester), isTrue);
        expect(find.byIcon(Icons.broken_image), findsNothing);
      });

      testWidgets('three failed retries end in a manual retry button', (
        tester,
      ) async {
        final network = pipeline()..script = (_) => _Outcome.transient;
        await _pump(tester, network);
        for (final wait in const [1, 3, 8]) {
          await tester.pump(Duration(seconds: wait));
          await _settle(tester);
        }
        expect(network.requests, 4);
        await tester.pump(const Duration(seconds: 30));
        expect(network.requests, 4);
        expect(find.byTooltip('重新加载图片'), findsOneWidget);
      });

      testWidgets('a missing image is asked for once; the button asks again', (
        tester,
      ) async {
        final network = pipeline()..script = (_) => _Outcome.notFound;
        await _pump(tester, network);
        await tester.pump(const Duration(seconds: 30));
        expect(network.requests, 1);

        await tester.tap(find.byIcon(Icons.refresh));
        await _settle(tester);
        expect(network.requests, 2);
      });

      testWidgets('a small image slot keeps the broken-image icon', (
        tester,
      ) async {
        final network = pipeline()..script = (_) => _Outcome.notFound;
        await _pump(tester, network, size: 32);
        expect(find.byIcon(Icons.refresh), findsNothing);
        expect(find.byIcon(Icons.broken_image), findsOneWidget);
      });

      testWidgets('a pending retry dies with the widget', (tester) async {
        final network = pipeline()..script = (_) => _Outcome.transient;
        await _pump(tester, network);
        expect(network.requests, 1);
        await tester.pumpWidget(const SizedBox());
        // flutter_test fails the test if the backoff timer is still pending.
        expect(network.requests, 1);
      });
    });
  }
}
