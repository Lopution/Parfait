import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
import 'package:pixiv_func/app/motion/drag_to_dismiss.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/features/illust/detail/ugoira_viewer.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

void main() {
  installMemoryPreferences();
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  testWidgets('renders the beta56 cover, play affordance and GIF badge', (
    tester,
  ) async {
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

      expect(find.byIcon(Icons.play_circle_outline_outlined), findsOneWidget);
      expect(find.byIcon(Icons.gif_box_outlined), findsOneWidget);
      expect(find.byType(DragToDismiss), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
    });
  });

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
      MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: const SizedBox.shrink(),
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
}
