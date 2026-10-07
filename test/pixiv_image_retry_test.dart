import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
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

/// One URL per pipeline: only an original file still loads on the legacy
/// one, and its uncapped decode is recorded app-wide — a capped request for
/// a URL with one paints that instead.
const _legacyUrl = 'https://i.pximg.net/img-original/retry-legacy.png';
const _workerUrl = 'https://i.pximg.net/img-master/retry-worker.jpg';

/// What the network does on one attempt.
enum _Outcome { transient, notFound, image }

/// Both image pipelines behind one script: the legacy cache manager (an
/// original file) and the background worker (a capped image). The retry
/// policy above them is shared, so every test runs on each.
abstract class _Pipeline {
  _Outcome Function(int attempt) script = (_) => _Outcome.image;
  var requests = 0;

  PixivImage get image;
  Future<List<Override>> overrides(WidgetTester tester);
}

class _LegacyPipeline extends _Pipeline {
  @override
  PixivImage get image => const PixivImage(url: _legacyUrl);

  @override
  Future<List<Override>> overrides(WidgetTester tester) async {
    final download = await onePixelPngDownload(tester, _legacyUrl);
    final manager = ScriptedCacheManager((_) {
      requests++;
      return switch (script(requests)) {
        _Outcome.transient => Stream.error(
          const SocketException('connection reset'),
        ),
        _Outcome.notFound => Stream.error(
          HttpExceptionWithStatus(404, 'not found'),
        ),
        _Outcome.image => Stream.value(download),
      };
    });
    return [
      pixivNetworkFactoryProvider.overrideWithValue(
        ScriptedImageNetwork(manager),
      ),
      imageWorkerProvider.overrideWithValue(legacyOnlyImageWorker()),
    ];
  }
}

class _WorkerPipeline extends _Pipeline {
  @override
  PixivImage get image => const PixivImage(url: _workerUrl, memCacheWidth: 200);

  @override
  Future<List<Override>> overrides(WidgetTester tester) async {
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
          ScriptedCacheManager((_) => fail('a worker image reached legacy')),
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
      overrides: await pipeline.overrides(tester),
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
    _LegacyPipeline.new,
    _WorkerPipeline.new,
  ]) {
    group(pipeline().runtimeType.toString(), () {
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
