import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/image_network.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_recovery.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/logging/crash_log.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/ugoira/ugoira_providers.dart';
import 'package:parfait/core/ugoira/ugoira_repository.dart';
import 'package:parfait/core/ugoira/ugoira_limits.dart';
import 'package:parfait/features/illust/detail/ugoira_viewer.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'helpers/api_responses.dart';
import 'helpers/connectivity_channels.dart';
import 'helpers/download_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/localized_app.dart';
import 'helpers/prompt_host.dart';
import 'helpers/waits.dart';
import 'package:parfait/app/icons/app_icons.dart';

void main() {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  testWidgets(
    'a long-press is inert — ugoira never enters page selection and the '
    'export affordance stays directly visible',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: localizedApp(
            home: const Scaffold(
              body: UgoiraViewer(
                illustId: 42,
                previewUrl: 'https://i.pximg.net/42/large.jpg',
                width: 800,
                height: 600,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The old long-press handoff into the detail page's download mode
      // is gone: ugoira has no pages to select. The press must not
      // toggle playback or open anything.
      await tester.longPress(find.byType(UgoiraViewer));
      await tester.pump();

      expect(find.byType(UgoiraViewer), findsOneWidget);
      expect(find.byIcon(AppIcons.playCircle), findsOneWidget);
      // The export entry stays rendered (a disabled IconButton while the
      // asset has not loaded yet).
      expect(
        find.descendant(
          of: find.byType(UgoiraViewer),
          matching: find.byType(IconButton),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('a vertical drag scrolls the detail page instead of popping it', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      withStalledImages(
        localizedApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
      ),
    );
    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: ListView(
            children: const [
              UgoiraViewer(
                illustId: 42,
                previewUrl: 'https://i.pximg.net/42/large.jpg',
                width: 800,
                height: 600,
              ),
              SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The inline Ugoira surface lives inside the detail page; a downward
    // drag on it must scroll the page, never dismiss the route.
    await tester.drag(find.byType(UgoiraViewer), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(UgoiraViewer), const Offset(0, 180));
    await tester.pumpAndSettle();

    expect(find.byType(UgoiraViewer), findsOneWidget);
  });

  testWidgets('a disposed viewer ignores a late visibility callback', (
    tester,
  ) async {
    await tester.pumpWidget(
      withStalledImages(
        localizedApp(
          body: UgoiraViewer(
            illustId: 42,
            previewUrl: 'https://i.pximg.net/42/large.jpg',
            width: 800,
            height: 600,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    VisibilityDetectorController.instance.notifyNow();
    expect(tester.takeException(), isNull);
  });

  /// The viewer over the app's ugoira pipeline, whose ZIP download says
  /// it is larger than an archive may be.
  Future<void> pumpFailingViewer(WidgetTester tester) async {
    answerConnectivityChannels();
    final temporary = Directory.systemTemp.createTempSync('ugoira-viewer-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final zip = FakeTransport()
      ..responses.add(
        ScriptedResponse(
          contentLength: const UgoiraLimits().maxArchiveCompressedBytes + 1,
        ),
      );
    final container = await signedInApiContainer(
      PixivApi({
        '/v1/ugoira/metadata': answer({
          'ugoira_metadata': {
            'frames': [
              {'file': '0.jpg', 'delay': 100},
            ],
            'zip_urls': {'medium': 'https://i.pximg.net/42/ugoira.zip'},
          },
        }),
      }).client,
      overrides: [
        // The platform's temporary directory, here one of the test's own.
        ugoiraRepositoryProvider.overrideWith(
          (ref) => UgoiraRepository(
            client: ref.watch(pixivHttpClientProvider),
            transport: zip,
            temporaryDirectory: () async => temporary,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      localizedApp(
        container: container,
        body: UgoiraViewer(
          illustId: 42,
          previewUrl: 'https://i.pximg.net/42/large.jpg',
          width: 800,
          height: 600,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(UgoiraViewer));
    // The load creates and removes its file on real IO.
    await pumpIoUntil(tester, () => find.text('动图压缩包无效').tryEvaluate());
  }

  testWidgets('a specific failure headline records its diagnostic', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('ugoira-crash-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final log = File('${dir.path}/crash.log');
    CrashLog.useFile(log);
    addTearDown(() => CrashLog.useFile(null));
    await pumpFailingViewer(tester);

    // The headline names the problem, so no generic category line rides
    // under it, and the raw reason is not interpolated into the copy.
    expect(find.text('动图压缩包无效'), findsOneWidget);
    expect(find.text('未知错误'), findsNothing);
    expect(find.textContaining('compressed limit'), findsNothing);

    // The raw reason goes to the crash log under the headline.
    await pumpIoUntil(
      tester,
      () => log.existsSync() && log.readAsStringSync().contains('limit'),
    );
    final logged = log.readAsStringSync();
    expect(logged, contains('reported: 动图压缩包无效'));
    expect(
      logged,
      contains('UgoiraArchiveException: archive exceeds compressed limit'),
    );
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets(
    'UgoiraViewer exports GIF on demand without prior playback, survives leaving page, and shows progress/cancel on re-entry',
    (tester) async {
      answerConnectivityChannels();
      final tempDir = Directory.systemTemp.createTempSync('ugoira-ui-');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final zipBytes = ZipEncoder().encode(
        Archive()..addFile(ArchiveFile('0.png', png.length, png)),
      );
      final transport = FakeTransport()
        ..responses.addAll([
          ScriptedResponse(chunks: [zipBytes]),
          ScriptedResponse(chunks: [zipBytes]),
        ]);
      final sinks = MemorySinkFactory();
      var gate = Completer<void>();
      final container = await signedInApiContainer(
        PixivApi({
          '/v1/ugoira/metadata': answer({
            'ugoira_metadata': {
              'frames': [
                {'file': '0.png', 'delay': 100},
              ],
              'zip_urls': {'medium': 'https://i.pximg.net/42/ugoira.zip'},
            },
          }),
        }).client,
        overrides: [
          downloadSinkFactoryProvider.overrideWithValue(sinks),
          ugoiraRecoveryStoreProvider.overrideWithValue(
            MemoryDownloadRecoveryStore(),
          ),
          ugoiraGifEncoderFactoryProvider.overrideWithValue(
            (_) => FakeUgoiraGifEncoder(gate: gate),
          ),
          ugoiraRepositoryProvider.overrideWith(
            (ref) => UgoiraRepository(
              client: ref.watch(pixivHttpClientProvider),
              transport: transport,
              temporaryDirectory: () async => tempDir,
            ),
          ),
        ],
      );
      final showViewer = ValueNotifier<bool>(true);
      addTearDown(showViewer.dispose);
      await tester.pumpWidget(
        withStalledImages(
          localizedApp(
            container: container,
            builder: promptHostBuilder,
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: showViewer,
                builder: (_, visible, _) => visible
                    ? const UgoiraViewer(
                        illustId: 42,
                        previewUrl: 'https://i.pximg.net/42/large.jpg',
                        width: 800,
                        height: 600,
                      )
                    : const Text('left-page'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // Export button is immediately enabled before playback starts.
      await tester.tap(find.byTooltip('保存 GIF'));
      await tester.pump();
      await pumpIoUntil(
        tester,
        () =>
            container.read(ugoiraExportControllerProvider)[42]?.phase ==
            UgoiraExportPhase.running,
      );
      // Leave the page while export runs; re-entering shows active Cancel.
      showViewer.value = false;
      await tester.pump();
      showViewer.value = true;
      await tester.pump();
      expect(find.byTooltip('取消'), findsOneWidget);

      // Leave again and let export finish; PromptHost still reports saved.
      showViewer.value = false;
      await tester.pump();
      gate.complete();
      await pumpIoUntil(tester, () => find.text('GIF 已保存').tryEvaluate());
      expect(tempDir.listSync(), isEmpty);

      // Start a second export and cancel from the viewer capsule.
      gate = Completer<void>();
      showViewer.value = true;
      await tester.pump();
      await tester.tap(find.byTooltip('保存 GIF'));
      await tester.pump();
      await pumpIoUntil(tester, () => find.byTooltip('取消').tryEvaluate());
      await tester.tap(find.byTooltip('取消'));
      await pumpIoUntil(tester, () => find.text('GIF 保存已取消').tryEvaluate());
      expect(tempDir.listSync(), isEmpty);
    },
  );

  testWidgets(
    'UgoiraViewer exposes play semantics, handles Enter key, and speed button keeps >=48dp hit target',
    (tester) async {
      answerConnectivityChannels();
      var metadataCalls = 0;
      final api = PixivApi({
        '/v1/ugoira/metadata': (request) {
          metadataCalls++;
          return answer({
            'ugoira_metadata': {
              'frames': [
                {'file': '0.jpg', 'delay': 100},
              ],
              'zip_urls': {'medium': 'https://i.pximg.net/42/ugoira.zip'},
            },
          })(request);
        },
      });
      final container = await signedInApiContainer(api.client);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          withStalledImages(
            localizedApp(
              container: container,
              home: const Scaffold(
                body: UgoiraViewer(
                  illustId: 42,
                  previewUrl: 'https://i.pximg.net/42/large.jpg',
                  width: 800,
                  height: 600,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.bySemanticsLabel('播放动图'), findsOneWidget);
        final speedFinder = find.byTooltip('播放倍速');
        expect(speedFinder, findsOneWidget);
        final speedSize = tester.getSize(speedFinder);
        expect(speedSize.width, greaterThanOrEqualTo(48));
        expect(speedSize.height, greaterThanOrEqualTo(48));

        // Focus viewer and press Enter to trigger playback load.
        final focus = tester.widget<Focus>(
          find.descendant(
            of: find.byType(UgoiraViewer),
            matching: find.byWidgetPredicate(
              (w) => w is Focus && w.focusNode != null,
            ),
          ),
        );
        focus.focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(metadataCalls, 1);
      } finally {
        semantics.dispose();
      }
    },
  );
}
