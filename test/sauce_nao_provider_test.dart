import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/reverse_image/image_input.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_provider.dart';
import 'package:pixiv_func/core/reverse_image/sauce_nao_provider.dart';

void main() {
  late Directory tempDirectory;
  late OwnedReverseImageInput input;

  setUp(() async {
    tempDirectory = Directory.systemTemp.createTempSync('sauce-nao-');
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(64, 64));
    input = await _open(file.path);
  });

  tearDown(() async {
    await input.dispose();
    if (tempDirectory.existsSync()) tempDirectory.deleteSync(recursive: true);
  });

  test(
    'posts a multipart file and returns a service-rendered html result',
    () async {
      String? method;
      String? url;
      String? contentType;
      String? body;
      final client = MockClient((request) async {
        method = request.method;
        url = request.url.toString();
        contentType = request.headers['content-type'];
        body = String.fromCharCodes(request.bodyBytes);
        return http.Response(
          '<html><body>results</body></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });
      final provider = SauceNaoWebViewProvider(client: client);

      final outcome = await provider.search(input);

      expect(method, 'POST');
      expect(url, SauceNaoWebViewProvider.defaultEndpoint);
      expect(contentType, contains('multipart/form-data'));
      expect(body, contains('dart-http-boundary'));
      expect(body, contains('name="file"'));
      expect(outcome, isA<ReverseImageSearchWebView>());
      final webView = outcome as ReverseImageSearchWebView;
      expect(webView.html, contains('results'));
      expect(webView.resultUrl, isNull);
    },
  );

  test('follows a redirect location into a controlled webview', () async {
    final client = MockClient(
      (request) async => http.Response(
        '',
        302,
        headers: {'location': 'https://saucenao.com/results?db=999&x=1'},
      ),
    );
    final provider = SauceNaoWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchWebView>());
    final webView = outcome as ReverseImageSearchWebView;
    expect(
      webView.resultUrl.toString(),
      'https://saucenao.com/results?db=999&x=1',
    );
    expect(webView.html, isNull);
  });

  test('rejects unsafe redirect targets', () async {
    final client = MockClient(
      (request) async => http.Response(
        '',
        302,
        headers: {'location': 'http://saucenao.com/results'},
      ),
    );
    final provider = SauceNaoWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchFailure>());
    expect(
      (outcome as ReverseImageSearchFailure).code,
      ReverseImageProviderFailureCode.malformedResponse,
    );
  });

  test('surfaces a 429 rate limit with retry-after', () async {
    final client = MockClient(
      (request) async =>
          http.Response('{}', 429, headers: {'retry-after': '27'}),
    );
    final provider = SauceNaoWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchFailure>());
    final failure = outcome as ReverseImageSearchFailure;
    expect(failure.code, ReverseImageProviderFailureCode.rateLimited);
    expect(failure.retryable, isTrue);
    expect(failure.retryAfter, const Duration(seconds: 27));
  });

  test('a non-HTML success body is never treated as a result page', () async {
    final client = MockClient(
      (request) async => http.Response(
        '{"error":"captcha"}',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final provider = SauceNaoWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchFailure>());
    expect(
      (outcome as ReverseImageSearchFailure).code,
      ReverseImageProviderFailureCode.malformedResponse,
    );
  });

  test('a 200 challenge or no-match HTML page is a visible failure', () async {
    final client = MockClient(
      (request) async => http.Response(
        '<html><body>captcha: verify you are human</body></html>',
        200,
        headers: {'content-type': 'text/html'},
      ),
    );
    final provider = SauceNaoWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchFailure>());
    expect(
      (outcome as ReverseImageSearchFailure).code,
      ReverseImageProviderFailureCode.challenge,
    );
  });

  test('a real anonymous result page (with the Cloudflare analytics beacon) '
      'is a webview result, not a challenge', () async {
    final fixture = File(
      'test/fixtures/saucenao/anonymous_result_page.html',
    ).readAsBytesSync();
    final client = MockClient(
      (request) async => http.Response.bytes(
        fixture,
        200,
        headers: {'content-type': 'text/html; charset=UTF-8'},
      ),
    );
    final provider = SauceNaoWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchWebView>());
    final html = (outcome as ReverseImageSearchWebView).html!;
    expect(html, contains('resulttable'));
    expect(html.toLowerCase(), contains('cloudflareinsights'));
  });

  test('a Cloudflare interstitial is still classified as a challenge', () async {
    const interstitial =
        '<!DOCTYPE html><html><head>'
        '<title>Just a moment...</title></head><body>'
        '<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1">'
        '</script></body></html>';
    final client = MockClient(
      (request) async => http.Response(
        interstitial,
        200,
        headers: {'content-type': 'text/html'},
      ),
    );
    final provider = SauceNaoWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchFailure>());
    expect(
      (outcome as ReverseImageSearchFailure).code,
      ReverseImageProviderFailureCode.challenge,
    );
  });

  test(
    'an Attention Required Cloudflare page is classified as a challenge',
    () async {
      const interstitial =
          '<!DOCTYPE html><html><head>'
          '<title>Attention Required! | Cloudflare</title></head><body>'
          '<form class="cf-turnstile"></form>'
          '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js">'
          '</script></body></html>';
      final client = MockClient(
        (request) async => http.Response(
          interstitial,
          200,
          headers: {'content-type': 'text/html'},
        ),
      );
      final provider = SauceNaoWebViewProvider(client: client);

      final outcome = await provider.search(input);

      expect(outcome, isA<ReverseImageSearchFailure>());
      expect(
        (outcome as ReverseImageSearchFailure).code,
        ReverseImageProviderFailureCode.challenge,
      );
    },
  );

  test('a 403 response is classified as a challenge', () async {
    final client = MockClient(
      (request) async => http.Response('forbidden', 403),
    );
    final provider = SauceNaoWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchFailure>());
    expect(
      (outcome as ReverseImageSearchFailure).code,
      ReverseImageProviderFailureCode.challenge,
    );
  });

  test('a rendered daily limit page is dailyLimit and retryable', () async {
    const text =
        'Daily Search Limit Exceeded. Your IP has exceeded the unregistered '
        "user's daily limit of 150 searches.";
    final client = MockClient(
      (request) async => http.Response(
        '<html><body>$text</body></html>',
        200,
        headers: {'content-type': 'text/html'},
      ),
    );
    final provider = SauceNaoWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchFailure>());
    final failure = outcome as ReverseImageSearchFailure;
    expect(failure.code, ReverseImageProviderFailureCode.dailyLimit);
    expect(failure.retryable, isTrue);
    expect(failure.retryAfter, isNull);
  });

  test(
    'a Search Rate Too High page is rateLimited with a 30s retryAfter',
    () async {
      const text =
          'Search Rate Too High. Please wait a moment before trying again.';
      final client = MockClient(
        (request) async => http.Response(
          '<html><body>$text</body></html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
      );
      final provider = SauceNaoWebViewProvider(client: client);

      final outcome = await provider.search(input);

      expect(outcome, isA<ReverseImageSearchFailure>());
      final failure = outcome as ReverseImageSearchFailure;
      expect(failure.code, ReverseImageProviderFailureCode.rateLimited);
      expect(failure.retryable, isTrue);
      expect(failure.retryAfter, const Duration(seconds: 30));
    },
  );

  test('decodes UTF-8 result HTML without corrupting non-ASCII text', () async {
    final client = MockClient(
      (request) async => http.Response.bytes(
        utf8.encode('<html><body>结果：你好</body></html>'),
        200,
        headers: {'content-type': 'text/html'},
      ),
    );
    final provider = SauceNaoWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchWebView>());
    expect((outcome as ReverseImageSearchWebView).html, contains('结果：你好'));
  });

  test('rejects a no-match HTML page', () async {
    final client = MockClient(
      (request) async => http.Response.bytes(
        utf8.encode('<html><body>没有匹配结果</body></html>'),
        200,
        headers: {'content-type': 'text/html'},
      ),
    );
    final provider = SauceNaoWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchSuccess>());
    expect((outcome as ReverseImageSearchSuccess).hits, isEmpty);
  });

  test('provider belongs to interactiveWebView and is enabled', () {
    final provider = SauceNaoWebViewProvider(
      client: MockClient((_) async {
        return http.Response('', 503);
      }),
    );
    final capability = provider.capability;
    expect(capability.kind, ReverseImageProviderKind.interactiveWebView);
    expect(capability.enabled, isTrue);
  });

  test('a cancelled search reports cancellation', () async {
    final client = MockClient(
      (request) async => http.Response(
        '<html>late</html>',
        200,
        headers: {'content-type': 'text/html'},
      ),
    );
    final provider = SauceNaoWebViewProvider(client: client);
    final token = CancelToken()..cancel();

    final outcome = await provider.search(input, cancelToken: token);

    expect(outcome, isA<ReverseImageSearchFailure>());
    expect(
      (outcome as ReverseImageSearchFailure).code,
      ReverseImageProviderFailureCode.cancelled,
    );
  });
}

Future<OwnedReverseImageInput> _open(String path) {
  return OwnedReverseImageInput.open(
    path: path,
    source: ReverseImageInputSource.picker,
    mimeType: 'image/png',
    delete: (_) async {},
  );
}

List<int> _pngHeader(int width, int height) => [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, //
  (width >> 24) & 0xff,
  (width >> 16) & 0xff,
  (width >> 8) & 0xff,
  width & 0xff, //
  (height >> 24) & 0xff,
  (height >> 16) & 0xff,
  (height >> 8) & 0xff,
  height & 0xff, //
  8, 6, 0, 0, 0, 0, 0, 0, 0,
];
