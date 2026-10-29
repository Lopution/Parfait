import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/share/share_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharePayload', () {
    test('each payload shares its title, author and canonical URL', () {
      for (final (payload, url, text) in [
        (
          SharePayload.illust(id: 1234, title: 'A piece', author: 'an artist'),
          'https://www.pixiv.net/artworks/1234',
          'A piece | an artist #Pixiv https://www.pixiv.net/artworks/1234',
        ),
        (
          SharePayload.novel(id: 77, title: 'A story', author: 'a writer'),
          'https://www.pixiv.net/novel/show.php?id=77',
          'A story | a writer #Pixiv https://www.pixiv.net/novel/show.php?id=77',
        ),
        (
          SharePayload.user(id: 42, name: 'tester'),
          'https://www.pixiv.net/users/42',
          'tester | tester #Pixiv https://www.pixiv.net/users/42',
        ),
      ]) {
        expect((payload.url, payload.text), (url, text));
      }
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
