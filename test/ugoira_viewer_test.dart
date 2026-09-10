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
      expect(find.byType(DragToDismiss), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
    });
  });

  testWidgets('keeps the long-press handoff owned by the detail page', (
    tester,
  ) async {
    var longPressed = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),

          home: Scaffold(
            body: UgoiraViewer(
              illustId: 42,
              previewUrl: 'https://i.pximg.net/42/large.jpg',
              width: 800,
              height: 600,
              onLongPress: () => longPressed = true,
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.byType(UgoiraViewer));

    expect(longPressed, isTrue);
  });

  testWidgets('dragging the detail surface pops its route', (tester) async {
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
        builder: (_) => const Scaffold(
          body: UgoiraViewer(
            illustId: 42,
            previewUrl: 'https://i.pximg.net/42/large.jpg',
            width: 800,
            height: 600,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(DragToDismiss), const Offset(0, 180));
    await tester.pumpAndSettle();

    expect(find.byType(UgoiraViewer), findsNothing);
  });
}
