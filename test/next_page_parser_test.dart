import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/network/next_page_parser.dart';
import 'package:parfait/core/search/search_models.dart';

void main() {
  group('NextPageParser', () {
    test('null and empty next_url mean no next page', () {
      expect(NextPageParser.parse(null), isNull);
      expect(NextPageParser.parse(''), isNull);
    });

    test('a Pixiv API cursor is accepted', () {
      final request = NextPageParser.parse(
        'https://app-api.pixiv.net/v1/illust/recommended?offset=30&filter=for_ios',
      );
      expect(request, isNotNull);
      expect(request!.query['offset'], '30');
    });

    test('real-device recommended next_url shape is accepted', () {
      // Captured from a live /v1/illust/recommended response: indexed
      // `viewed[n]` array params plus bookmark-recommend cursors. Pixiv owns
      // this cursor state and changes it; the parser must not enumerate it.
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

    test('a next_url may never leave the Pixiv API origin', () {
      const corpus = <String, String>{
        'plain http': 'http://app-api.pixiv.net/v1/illust/recommended?offset=0',
        'unknown host':
            'https://evil.example.com/v1/illust/recommended?offset=0',
        'userinfo host':
            'https://app-api.pixiv.net@evil.example.com/v1/illust/recommended',
        'non-default port':
            'https://app-api.pixiv.net:8443/v1/illust/recommended',
      };
      for (final entry in corpus.entries) {
        expect(
          () => NextPageParser.parse(entry.value),
          throwsA(isA<NextPageParseError>()),
          reason: entry.key,
        );
      }
    });

    test('an unrecognised path or parameter is Pixiv cursor state', () {
      // Repositories pin the endpoint and identity parameters they expect.
      // A parameter this client has never seen is not a reason to break paging.
      expect(
        NextPageParser.parse(
          'https://app-api.pixiv.net/v1/illust/recommended?offset=0&brand_new=1',
        )!.query['brand_new'],
        '1',
      );
      expect(
        NextPageParser.parse(
          'https://app-api.pixiv.net/v9/illust/something-new?offset=0',
        )!.uri.path,
        '/v9/illust/something-new',
      );
    });

    test('firstPage only builds requests this client knows how to send', () {
      expect(
        () => NextPageParser.firstPage('/v1/not/registered', {}),
        throwsA(isA<NextPageParseError>()),
      );
      expect(
        () => NextPageParser.firstPage('/v2/illust/follow', {'word': 'x'}),
        throwsA(isA<NextPageParseError>()),
      );
    });

    test(
      'every IllustSearchFilters and NovelSearchFilters query key is admitted by firstPage',
      () {
        // Reliability P1 c7d43c86: paired producer <-> allowlist contract.
        final illustQuery = IllustSearchFilters(
          target: SearchTarget.exactMatchForTags,
          sort: SearchSort.dateAsc,
          duration: SearchDuration.week,
          startDate: DateTime.utc(2026, 1, 1),
          endDate: DateTime.utc(2026, 2, 1),
          aiFilter: SearchAiFilter.exclude,
          bookmarkMin: 100,
          bookmarkMax: 5000,
          ratio: SearchRatioPattern.landscape,
          contentType: SearchContentType.manga,
          widthMin: 800,
          widthMax: 4000,
          heightMin: 600,
          heightMax: 3000,
        ).toQuery(word: 'landscape');
        final novelQuery = NovelSearchFilters(
          target: SearchTarget.text,
          sort: SearchSort.dateDesc,
          duration: SearchDuration.month,
          startDate: DateTime.utc(2026, 1, 1),
          endDate: DateTime.utc(2026, 2, 1),
          aiFilter: SearchAiFilter.exclude,
          bookmarkMin: 50,
          bookmarkMax: 1000,
          textLengthMin: 1000,
          textLengthMax: 20000,
          originalOnly: true,
        ).toQuery(word: 'fantasy');
        final previewIllust = Map<String, String>.from(illustQuery)
          ..remove('sort')
          ..remove('duration');
        final previewNovel = Map<String, String>.from(novelQuery)
          ..remove('sort')
          ..remove('duration');

        expect(
          NextPageParser.firstPage('/v1/search/illust', illustQuery).query,
          illustQuery,
        );
        expect(
          NextPageParser.firstPage(
            '/v1/search/popular-preview/illust',
            previewIllust,
          ).query,
          previewIllust,
        );
        expect(
          NextPageParser.firstPage('/v1/search/novel', novelQuery).query,
          novelQuery,
        );
        expect(
          NextPageParser.firstPage(
            '/v1/search/popular-preview/novel',
            previewNovel,
          ).query,
          previewNovel,
        );
      },
    );
  });
}
