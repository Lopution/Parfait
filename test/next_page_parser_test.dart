import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/network/next_page_parser.dart';

void main() {
  group('NextPageParser', () {
    test('null and empty next_url mean no next page', () {
      expect(NextPageParser.parse(null), isNull);
      expect(NextPageParser.parse(''), isNull);
    });

    test('allowlisted endpoint with known params is accepted', () {
      final request = NextPageParser.parse(
        'https://app-api.pixiv.net/v1/illust/recommended?offset=30&filter=for_ios',
      );
      expect(request, isNotNull);
      expect(request!.query['offset'], '30');
    });

    test('real-device recommended next_url shape is accepted', () {
      // Captured from a live /v1/illust/recommended response: indexed
      // `viewed[n]` array params plus bookmark-recommend cursors must pass
      // the allowlist, otherwise the whole feed errors out on page one.
      const realNextUrl =
          'https://app-api.pixiv.net/v1/illust/recommended'
          '?content_type=illust&include_ranking_illusts=false'
          '&filter=for_ios&min_bookmark_id_for_recent_illust=28598116435'
          '&max_bookmark_id_for_recommend=22338680892&offset=0'
          '&include_privacy_policy=false'
          '&viewed%5B0%5D=99683300&viewed%5B1%5D=145047042'
          '&viewed%5B2%5D=144816389';
      final request = NextPageParser.parse(realNextUrl)!;
      expect(request.uri.path, '/v1/illust/recommended');
      expect(
        request.uri.queryParameters['max_bookmark_id_for_recommend'],
        '22338680892',
      );
      expect(request.uri.queryParameters['viewed[1]'], '145047042');
    });

    test('firstPage builds a request for a registered endpoint', () {
      final request = NextPageParser.firstPage('/v2/illust/follow', {
        'restrict': 'public',
        'offset': '0',
      });
      expect(request.uri.path, '/v2/illust/follow');
      expect(request.query['restrict'], 'public');
    });

    test('malicious corpus is rejected', () {
      const corpus = <String, String>{
        'plain http': 'http://app-api.pixiv.net/v1/illust/recommended?offset=0',
        'unknown host':
            'https://evil.example.com/v1/illust/recommended?offset=0',
        'userinfo host':
            'https://app-api.pixiv.net@evil.example.com/v1/illust/recommended',
        'unknown endpoint': 'https://app-api.pixiv.net/v1/unknown/path',
        'path traversal':
            'https://app-api.pixiv.net/v1/illust/recommended/../../secret',
        'unknown query param':
            'https://app-api.pixiv.net/v1/illust/recommended?evil=1',
        'injected query param':
            'https://app-api.pixiv.net/v1/illust/recommended?offset=0&word=x',
        'firstPage unknown endpoint': '/v1/not/registered',
        'firstPage unknown param': '/v2/illust/follow',
      };
      // Direct next_url rejections.
      for (final entry in corpus.entries) {
        if (entry.key.startsWith('firstPage')) continue;
        String? nextUrl;
        if (entry.key == 'path traversal') {
          nextUrl =
              'https://app-api.pixiv.net/v1/illust/recommended/../../secret';
        }
        expect(
          () => NextPageParser.parse(nextUrl ?? entry.value),
          throwsA(isA<NextPageParseError>()),
          reason: entry.key,
        );
      }
      // firstPage-specific rejections.
      expect(
        () => NextPageParser.firstPage('/v1/not/registered', {}),
        throwsA(isA<NextPageParseError>()),
      );
      expect(
        () => NextPageParser.firstPage('/v2/illust/follow', {'word': 'x'}),
        throwsA(isA<NextPageParseError>()),
      );
    });
  });
}
