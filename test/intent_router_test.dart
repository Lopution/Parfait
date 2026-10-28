import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/platform/intent_router.dart';

void main() {
  group('IntentRouter allow table', () {
    test('app schemes and web paths map to typed routes', () {
      const web = 'https://www.pixiv.net';
      for (final (link, kind, id) in [
        ('pixiv://users/123', 'u', 123),
        ('pixiv://illusts/456', 'i', 456),
        ('parfait://users/9', 'u', 9),
        ('parfait://illusts/10', 'i', 10),
        ('$web/u/42', 'u', 42),
        ('$web/users/42', 'u', 42),
        ('https://pixiv.net/i/7', 'i', 7),
        ('$web/artworks/7', 'i', 7),
        ('$web/jump.php?illust_id=88', 'i', 88),
        ('$web/user.php?id=5', 'u', 5),
        // Changed: /en/artworks/<id> was previously UnknownRoute (unmapped).
        ('$web/en/artworks/1', 'i', 1),
        ('$web/en/users/9', 'u', 9),
        ('$web/en/i/3', 'i', 3),
        ('$web/ja/u/4', 'u', 4),
        ('$web/member_illust.php?mode=medium&illust_id=88', 'i', 88),
        ('$web/member_illust.php?mode=manga&illust_id=7', 'i', 7),
        ('$web/member.php?id=5', 'u', 5),
      ]) {
        final route = IntentRouter.route(Uri.parse(link));
        expect(
          route,
          kind == 'u'
              ? isA<UserRoute>().having((r) => r.userId, 'userId', id)
              : isA<IllustRoute>().having((r) => r.illustId, 'illustId', id),
          reason: link,
        );
      }
    });

    test('pixiv account callback carries the code', () {
      final route = IntentRouter.route(Uri.parse('pixiv://account?code=xyz'));
      expect(route, isA<AccountCallbackRoute>());
      expect((route as AccountCallbackRoute).code, 'xyz');
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
        Uri.parse('pixiv://account?code=%FF'),
        Uri.parse('https://www.pixiv.net/jump.php?illust_id=%FF'),
        Uri.parse('parfait://settings/1'),
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
      final route = IntentRouter.route(Uri.parse('https://www.pixiv.net/help'));
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

    test('rejects extra path segments, fragments and ambiguous query routes', () {
      for (final uri in [
        Uri.parse('pixiv://users/1/extra'),
        Uri.parse('parfait://illusts/1?unexpected=true'),
        Uri.parse('https://www.pixiv.net/foo/u/1'),
        Uri.parse('https://www.pixiv.net/u/1/extra'),
        Uri.parse('https://www.pixiv.net/u/1#fragment'),
        Uri.parse('https://www.pixiv.net/jump.php?illust_id=1&id=2'),
        Uri.parse('https://www.pixiv.net/EN/artworks/1'),
        Uri.parse('https://www.pixiv.net/eng/artworks/1'),
        Uri.parse('https://www.pixiv.net/en/artworks/1/extra'),
        Uri.parse('https://www.pixiv.net/member_illust.php?illust_id=1&foo=2'),
        Uri.parse('https://www.pixiv.net/member_illust.php?mode=medium'),
        Uri.parse('https://www.pixiv.net/member.php?id=1&x=2'),
        Uri.parse('https://www.pixiv.net/member.php?id=0'),
        Uri.parse('https://www.pixiv.net/en/en/artworks/1'),
        Uri.parse('https://www.pixiv.net/en/artworks/12345?p=1'),
        Uri.parse(
          'https://www.pixiv.net/member_illust.php?mode=medium&mode=manga&illust_id=1',
        ),
        Uri.parse('https://user:pass@www.pixiv.net/artworks/1'),
      ]) {
        expect(IntentRouter.route(uri), isA<UnknownRoute>(), reason: '$uri');
      }
    });
  });
}
