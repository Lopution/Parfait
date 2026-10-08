import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/image_network.dart';
import 'helpers/test_preferences.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/ugoira/ugoira_providers.dart';
import 'package:parfait/core/ugoira/ugoira_repository.dart';
import 'package:parfait/core/ugoira/ugoira_zip.dart';
import 'package:parfait/features/illust/detail/ugoira_viewer.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

void main() {
  installMemoryPreferences();
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  testWidgets(
    'a long-press is inert — ugoira never enters page selection and the '
    'export affordance stays directly visible',
    (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          const ProviderScope(
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: Locale('zh', 'CN'),

              home: Scaffold(
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
      });
    },
  );

  testWidgets('a vertical drag scrolls the detail page instead of popping it', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      withStalledImages(
        MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: const SizedBox.shrink(),
        ),
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
        const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: Scaffold(
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
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    VisibilityDetectorController.instance.notifyNow();
    expect(tester.takeException(), isNull);
  });

  Future<void> pumpFailingViewer(WidgetTester tester, Object failure) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ugoiraRepositoryProvider.overrideWithValue(
            _FailingUgoiraRepository(failure),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: Scaffold(
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
    await tester.tap(find.byType(UgoiraViewer));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a specific failure headline keeps its diagnostic in details', (
    tester,
  ) async {
    await mockNetworkImagesFor(() async {
      await pumpFailingViewer(
        tester,
        const UgoiraArchiveException('JPEG marker is malformed'),
      );

      // The headline names the problem, so no generic category line rides
      // under it, and the raw reason is not interpolated into the copy.
      expect(find.text('动图压缩包无效'), findsOneWidget);
      expect(find.text('未知错误'), findsNothing);
      expect(find.textContaining('JPEG marker'), findsNothing);

      await tester.tap(find.text('详情'));
      await tester.pump();
      expect(
        find.text('UgoiraArchiveException: JPEG marker is malformed'),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 500));
    });
  });
}

/// Repository boundary stand-in: the network/ZIP pipeline is replaced, the
/// viewer's own failure presentation runs for real.
class _FailingUgoiraRepository implements UgoiraRepository {
  _FailingUgoiraRepository(this.failure);

  final Object failure;

  @override
  Future<UgoiraAsset> load(int illustId, {CancelToken? cancelToken}) async {
    throw failure;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
