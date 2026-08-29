import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/platform/intent_router.dart';

void main() {
  group('Android intent boundary', () {
    test('routes only an explicit VIEW deep link', () {
      final result = IntentRouter.routeIntent(
        AndroidIntentInput(
          action: AndroidIntentInput.viewAction,
          uri: Uri.parse('https://www.pixiv.net/artworks/123'),
        ),
      );
      expect(result, isA<RoutedAndroidIntent>());
      expect((result as RoutedAndroidIntent).route, isA<IllustRoute>());
    });

    test('rejects SEND without the exact stream extra and read grant', () {
      final result = IntentRouter.routeIntent(
        AndroidIntentInput(
          action: AndroidIntentInput.sendAction,
          uri: Uri.parse('content://share/1'),
          mimeType: 'image/png',
          sizeBytes: 128,
          hasReadUriPermission: false,
        ),
      );
      expect(result, isA<RejectedAndroidIntent>());
      expect(
        (result as RejectedAndroidIntent).code,
        AndroidIntentRejectionCode.missingStreamExtra,
      );
    });

    test(
      'accepts a bounded content URI only with the stream extra and grant',
      () {
        final result = IntentRouter.routeIntent(
          AndroidIntentInput(
            action: AndroidIntentInput.sendAction,
            uri: Uri.parse('content://share/1'),
            mimeType: 'IMAGE/PNG',
            sizeBytes: 128,
            hasReadUriPermission: true,
            extraKeys: const {AndroidIntentInput.streamExtra},
          ),
        );
        expect(result, isA<SharedImageAndroidIntent>());
        final image = result as SharedImageAndroidIntent;
        expect(image.contentUri.toString(), 'content://share/1');
        expect(image.sizeBytes, 128);
      },
    );

    test('rejects foreign, file and oversized shared payloads', () {
      final inputs = [
        AndroidIntentInput(
          action: AndroidIntentInput.sendAction,
          uri: Uri.parse('file:///sdcard/a.png'),
          mimeType: 'image/png',
          sizeBytes: 1,
          hasReadUriPermission: true,
          extraKeys: const {AndroidIntentInput.streamExtra},
        ),
        AndroidIntentInput(
          action: AndroidIntentInput.sendAction,
          uri: Uri.parse('content://share/1'),
          mimeType: 'text/plain',
          sizeBytes: 1,
          hasReadUriPermission: true,
          extraKeys: const {AndroidIntentInput.streamExtra},
        ),
        AndroidIntentInput(
          action: AndroidIntentInput.sendAction,
          uri: Uri.parse('content://share/1'),
          mimeType: 'image/png',
          sizeBytes: 10 * 1024 * 1024 + 1,
          hasReadUriPermission: true,
          extraKeys: const {AndroidIntentInput.streamExtra},
        ),
      ];

      for (final input in inputs) {
        expect(IntentRouter.routeIntent(input), isA<RejectedAndroidIntent>());
      }
    });
  });
}
