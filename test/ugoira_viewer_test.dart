import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/image_network.dart';
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
import 'helpers/waits.dart';

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
      expect(find.byIcon(Icons.play_circle_outline_outlined), findsOneWidget);
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
    await pumpIoUntil(tester, () => find.text('详情').tryEvaluate());
  }

  testWidgets('a specific failure headline keeps its diagnostic in details', (
    tester,
  ) async {
    await pumpFailingViewer(tester);

    // The headline names the problem, so no generic category line rides
    // under it, and the raw reason is not interpolated into the copy.
    expect(find.text('动图压缩包无效'), findsOneWidget);
    expect(find.text('未知错误'), findsNothing);
    expect(find.textContaining('compressed limit'), findsNothing);

    await tester.tap(find.text('详情'));
    await tester.pump();
    expect(
      find.text('UgoiraArchiveException: archive exceeds compressed limit'),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 500));
  });
}
