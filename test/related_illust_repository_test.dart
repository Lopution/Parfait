import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/illust/related_illust_repository.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';

http.Response _ok(Map<String, dynamic> body) => jsonResponse(body);

Future<PixivRelatedIllustRepository> _repo(MockClient client) async {
  final container = await signedInApiContainer(client);
  return PixivRelatedIllustRepository(container.read(pixivHttpClientProvider));
}

void main() {
  group('PixivRelatedIllustRepository', () {
    test('requests /v2/illust/related with illust_id and filter', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v2/illust/related');
        expect(request.url.queryParameters['illust_id'], '42');
        expect(request.url.queryParameters['filter'], 'for_android');
        return _ok({'illusts': <Object?>[], 'next_url': null});
      });
      final repo = await _repo(client);
      final page = await repo.fetchPage(42);
      expect(page.illusts, isEmpty);
      expect(page.nextUrl, isNull);
    });

    test('parses illusts and next_url', () async {
      final client = MockClient(
        (request) async => _ok({
          'illusts': [
            illustJson(901, pageCount: 1),
            illustJson(902, pageCount: 2, withMetaPages: true),
          ],
          'next_url':
              'https://app-api.pixiv.net/v2/illust/related'
              '?illust_id=42&filter=for_ios&offset=2',
        }),
      );
      final repo = await _repo(client);
      final page = await repo.fetchPage(42);
      expect(page.illusts.map((e) => e.id), [901, 902]);
      expect(page.illusts[1].pageCount, 2);
      expect(page.nextUrl, contains('offset=2'));
    });

    test('malformed envelope raises ApiParseError', () async {
      final client = MockClient((request) async => _ok({'bogus': true}));
      final repo = await _repo(client);
      expect(() => repo.fetchPage(42), throwsA(isA<ApiParseError>()));
    });
  });
}
