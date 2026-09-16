import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/novel/novel_repository.dart';
import 'package:pixiv_func/core/novel/novel_webview_text.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

Future<ProviderContainer> _apiContainer(
  Future<http.Response> Function(http.Request) handler,
) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final credentials = FakeCredentialStore(
    values: const {
      'account': Credential(
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
      ),
    },
  );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: 'account', userId: 10, name: 'tester')],
          currentId: 'account',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient(
            (_) async => throw StateError('refresh is not expected'),
          ),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client is not wired');
        return client;
      }),
    ],
  );
  final client = PixivHttpClient(
    client: MockClient(handler),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  return container;
}

Map<String, dynamic> _detailJson(int id) => {
  'novel': {
    'id': id,
    'title': 'novel $id',
    'caption': 'caption $id',
    'restrict': 0,
    'x_restrict': 0,
    'is_original': false,
    'is_bookmarked': false,
    'text_length': 1234,
    'visible': true,
    'user': {
      'id': 10,
      'name': 'user 10',
      'account': 'user_10',
      'profile_image_urls': <String, String>{},
    },
    'tags': [
      {'name': 'tag1', 'translated_name': 't1'},
    ],
    'image_urls': <String, String>{},
    'series': {'id': 77, 'title': 'series 77'},
  },
};

/// Minimal real-shape webview page: the pixiv object is installed via
/// Object.defineProperty and carries the novel payload under `novel`.
String _webviewHtml({
  required String text,
  Map<String, dynamic>? images,
  Map<String, dynamic>? illusts,
  Map<String, dynamic>? seriesNavigation,
  bool trailingComma = false,
}) {
  final novel = <String, dynamic>{
    'id': '1',
    'title': 'novel 1',
    'text': text,
    'userId': '10',
    'coverUrl': 'https://i.pximg.net/c/1.jpg',
    'tags': <String>['tag1'],
    'caption': 'caption 1',
    'images': ?images,
    'illusts': ?illusts,
    'seriesNavigation': ?seriesNavigation,
  };
  var novelJson = jsonEncode(novel);
  if (trailingComma) {
    // Real-world pages ship trailing commas; the extractor must tolerate them.
    novelJson = novelJson.replaceAll('}', ',}');
  }
  return '''
<!DOCTYPE html><html><head></head><body>
<script>
Object.defineProperty(window, 'pixiv', {value: {
  "context": {"csrfToken": "x"},
  "novel": $novelJson,
  "foo": {"bar": {"nested": true}},
}, configurable: true, writable: true});
</script>
</body></html>
''';
}

void main() {
  group('extractNovelWebPayload', () {
    test('extracts text, images, illusts and series navigation', () {
      final payload = extractNovelWebPayload(
        _webviewHtml(
          text: 'first\n[newpage]\nsecond',
          images: const {
            'img-1': {
              'novelImageId': 55,
              'urls': {'original': 'https://i.pximg.net/img-1.png'},
            },
          },
          illusts: const {
            'i-9': {
              'id': 9,
              'illust': {
                'id': '9',
                'images': {'medium': 'https://i.pximg.net/9-m.jpg'},
              },
            },
          },
          seriesNavigation: const {
            'prevNovel': {'id': 100},
            'nextNovel': {'id': 102},
          },
        ),
      );
      expect(payload.text, contains('[newpage]'));
      expect(payload.images['img-1'], 'https://i.pximg.net/img-1.png');
      expect(payload.illustThumbs['i-9'], 'https://i.pximg.net/9-m.jpg');
      expect(payload.seriesPrevId, 100);
      expect(payload.seriesNextId, 102);
    });

    test('tolerates trailing commas in the embedded object', () {
      final payload = extractNovelWebPayload(
        _webviewHtml(text: 'body', trailingComma: true),
      );
      expect(payload.text, 'body');
    });

    test('rejects a page without the pixiv bootstrap script', () {
      expect(
        () => extractNovelWebPayload('<html><body>no script</body></html>'),
        throwsA(isA<ApiParseError>()),
      );
    });

    test('rejects a truncated embedded object', () {
      const html = """
<script>Object.defineProperty(window, 'pixiv', {value: {"novel": {"text": "cut"</script>""";
      expect(() => extractNovelWebPayload(html), throwsA(isA<ApiParseError>()));
    });
  });

  group('fetchDetail', () {
    test('merges webview text into the detail entity', () async {
      final container = await _apiContainer((request) async {
        if (request.url.path == '/v2/novel/detail') {
          return http.Response.bytes(
            utf8.encode(jsonEncode(_detailJson(1))),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/webview/v2/novel') {
          return http.Response.bytes(
            utf8.encode(_webviewHtml(text: 'para1\npara2')),
            200,
            headers: {'content-type': 'text/html'},
          );
        }
        return http.Response('not found', 404);
      });
      addTearDown(container.dispose);

      final novel = await container
          .read(novelRepositoryProvider)
          .fetchDetail(1);
      expect(novel.contentAvailable, isTrue);
      expect(novel.paragraphs, isNotEmpty);
      expect(novel.plainText, contains('para1'));
      expect(novel.seriesId, 77);
    });

    test('propagates webview transport failure as an API error', () async {
      final container = await _apiContainer((request) async {
        if (request.url.path == '/v2/novel/detail') {
          return http.Response.bytes(
            utf8.encode(jsonEncode(_detailJson(1))),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('boom', 500);
      });
      addTearDown(container.dispose);

      await expectLater(
        container.read(novelRepositoryProvider).fetchDetail(1),
        throwsA(isA<ApiHttpError>()),
      );
    });
  });
}
