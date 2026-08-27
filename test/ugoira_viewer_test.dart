import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/features/illust/detail/ugoira_viewer.dart';
import 'package:visibility_detector/visibility_detector.dart';

void main() {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  testWidgets('renders the beta56 cover, play affordance and GIF badge', (
    tester,
  ) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
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
}
