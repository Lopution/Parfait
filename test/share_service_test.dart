import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/share/share_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharePayload', () {
    test('illust payload follows the Shaft text contract', () {
      final payload = SharePayload.illust(
        id: 1234,
        title: 'A piece',
        author: 'an artist',
      );
      expect(payload.url, 'https://www.pixiv.net/artworks/1234');
      expect(
        payload.text,
        'A piece | an artist #Pixiv https://www.pixiv.net/artworks/1234',
      );
    });

    test('novel payload points at the canonical show.php URL', () {
      final payload = SharePayload.novel(
        id: 77,
        title: 'A story',
        author: 'a writer',
      );
      expect(
        payload.text,
        'A story | a writer #Pixiv https://www.pixiv.net/novel/show.php?id=77',
      );
    });

    test('user payload shares the profile URL', () {
      final payload = SharePayload.user(id: 42, name: 'tester');
      expect(
        payload.text,
        'tester | tester #Pixiv https://www.pixiv.net/users/42',
      );
    });
  });

  group('SystemShareService', () {
    test('missing platform support falls back to the clipboard', () async {
      final payload = SharePayload.user(id: 42, name: 'tester');
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      // share_plus has no implementation in the test environment, so the
      // plugin throws and the service must degrade to a clipboard copy
      // instead of surfacing an error.
      final outcome = await const SystemShareService().share(payload);
      expect(outcome, ShareOutcome.copiedToClipboard);
      expect(copied, payload.text);
    });
  });
}
