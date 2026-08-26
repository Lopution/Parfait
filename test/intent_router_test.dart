import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/platform/intent_router.dart';

void main() {
  group('IntentRouter allow table', () {
    test('pixiv scheme typed routes', () {
      expect(
        IntentRouter.route(Uri.parse('pixiv://users/123')),
        isA<UserRoute>().having((r) => r.userId, 'userId', 123),
      );
      expect(
        IntentRouter.route(Uri.parse('pixiv://illusts/456')),
        isA<IllustRoute>().having((r) => r.illustId, 'illustId', 456),
      );
    });

    test('pixiv account callback carries the code', () {
      final route = IntentRouter.route(Uri.parse('pixiv://account?code=xyz'));
      expect(route, isA<AccountCallbackRoute>());
      expect((route as AccountCallbackRoute).code, 'xyz');
    });

    test('pixivfunc scheme typed routes', () {
      expect(
        IntentRouter.route(Uri.parse('pixivfunc://users/9')),
        isA<UserRoute>().having((r) => r.userId, 'userId', 9),
      );
      expect(
        IntentRouter.route(Uri.parse('pixivfunc://illusts/10')),
        isA<IllustRoute>().having((r) => r.illustId, 'illustId', 10),
      );
    });

    test('web paths map to typed routes', () {
      expect(
        IntentRouter.route(Uri.parse('https://www.pixiv.net/u/42')),
        isA<UserRoute>().having((r) => r.userId, 'userId', 42),
      );
      expect(
        IntentRouter.route(Uri.parse('https://www.pixiv.net/users/42')),
        isA<UserRoute>(),
      );
      expect(
        IntentRouter.route(Uri.parse('https://pixiv.net/i/7')),
        isA<IllustRoute>().having((r) => r.illustId, 'illustId', 7),
      );
      expect(
        IntentRouter.route(Uri.parse('https://www.pixiv.net/artworks/7')),
        isA<IllustRoute>(),
      );
      expect(
        IntentRouter.route(
          Uri.parse('https://www.pixiv.net/jump.php?illust_id=88'),
        ),
        isA<IllustRoute>().having((r) => r.illustId, 'illustId', 88),
      );
      expect(
        IntentRouter.route(Uri.parse('https://www.pixiv.net/user.php?id=5')),
        isA<UserRoute>().having((r) => r.userId, 'userId', 5),
      );
    });
  });

  group('IntentRouter deny table', () {
    test('malformed pixiv links are UnknownRoute, never crash', () {
      for (final uri in [
        Uri.parse('pixiv://users/'),
        Uri.parse('pixiv://users/abc'),
        Uri.parse('pixiv://users/-1'),
        Uri.parse('pixiv://illusts'),
        Uri.parse('pixiv://unknown/1'),
        Uri.parse('pixiv://account'),
        Uri.parse('pixiv://account?code='),
        Uri.parse('pixiv://account?code=a&code=b'),
        Uri.parse('pixivfunc://settings/1'),
      ]) {
        final route = IntentRouter.route(uri);
        expect(route, isA<UnknownRoute>(), reason: '$uri');
      }
    });

    test('foreign schemes and hosts are ignored', () {
      for (final uri in [
        Uri.parse('https://evil.example.com/u/1'),
        Uri.parse('http://pixiv.net.evil.com/u/1'),
        Uri.parse('ftp://www.pixiv.net/u/1'),
        Uri.parse('intent://foo#Intent;scheme=http;end'),
      ]) {
        final route = IntentRouter.route(uri);
        expect(route, isA<ForeignUri>(), reason: '$uri');
      }
    });

    test('unmapped pixiv.net paths are UnknownRoute, not ForeignUri', () {
      final route = IntentRouter.route(
        Uri.parse('https://www.pixiv.net/help'),
      );
      expect(route, isA<UnknownRoute>());
    });

    test('invalid query ids are UnknownRoute', () {
      expect(
        IntentRouter.route(
          Uri.parse('https://www.pixiv.net/jump.php?illust_id=nope'),
        ),
        isA<UnknownRoute>(),
      );
    });
  });
}
