import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/reverse_image/image_input.dart';
import 'package:parfait/core/reverse_image/reverse_image_provider.dart';
import 'package:parfait/core/reverse_image/sauce_nao_provider.dart';
import 'helpers/image_headers.dart';

void main() {
  late Directory tempDirectory;
  late OwnedReverseImageInput input;

  setUp(() async {
    tempDirectory = Directory.systemTemp.createTempSync('sauce-nao-');
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(pngHeader(64, 64));
    input = await _open(file.path);
  });

  tearDown(() async {
    await input.dispose();
    if (tempDirectory.existsSync()) tempDirectory.deleteSync(recursive: true);
  });

  Future<ReverseImageSearchOutcome> answer(http.Response response) =>
      SauceNaoWebViewProvider(
        client: MockClient((_) async => response),
      ).search(input);

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

  // Answers the user sees as a failure, never as a result page.
  for (final (name, response, code) in [
    (
      'an unsafe redirect target',
      http.Response('', 302, headers: {'location': 'http://saucenao.com/x'}),
      ReverseImageProviderFailureCode.malformedResponse,
    ),
    (
      'a non-HTML success body',
      http.Response(
        '{"error":"captcha"}',
        200,
        headers: {'content-type': 'application/json'},
      ),
      ReverseImageProviderFailureCode.malformedResponse,
    ),
    (
      'a 200 captcha page',
      _html('<html><body>captcha: verify you are human</body></html>'),
      ReverseImageProviderFailureCode.challenge,
    ),
    (
      'a Cloudflare interstitial',
      _html(
        '<!DOCTYPE html><html><head>'
        '<title>Just a moment...</title></head><body>'
        '<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1">'
        '</script></body></html>',
      ),
      ReverseImageProviderFailureCode.challenge,
    ),
    (
      'an Attention Required Cloudflare page',
      _html(
        '<!DOCTYPE html><html><head>'
        '<title>Attention Required! | Cloudflare</title></head><body>'
        '<form class="cf-turnstile"></form>'
        '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js">'
        '</script></body></html>',
      ),
      ReverseImageProviderFailureCode.challenge,
    ),
    (
      'a 403 response',
      http.Response('forbidden', 403),
      ReverseImageProviderFailureCode.challenge,
    ),
  ]) {
    test('$name fails as ${code.name}', () async {
      expect(
        await answer(response),
        isA<ReverseImageSearchFailure>().having((f) => f.code, 'code', code),
      );
    });
  }

  // Limits are retryable, with the wait the service names when it names one.
  for (final (name, response, code, retryAfter) in [
    (
      'a 429 with retry-after',
      http.Response('{}', 429, headers: {'retry-after': '27'}),
      ReverseImageProviderFailureCode.rateLimited,
      const Duration(seconds: 27),
    ),
    (
      'a rendered daily limit page',
      _html(
        '<html><body>Daily Search Limit Exceeded. Your IP has exceeded the '
        "unregistered user's daily limit of 150 searches.</body></html>",
      ),
      ReverseImageProviderFailureCode.dailyLimit,
      null,
    ),
    (
      'a Search Rate Too High page',
      _html(
        '<html><body>Search Rate Too High. Please wait a moment before '
        'trying again.</body></html>',
      ),
      ReverseImageProviderFailureCode.rateLimited,
      const Duration(seconds: 30),
    ),
  ]) {
    test('$name is a retryable ${code.name}', () async {
      final failure = await answer(response) as ReverseImageSearchFailure;
      expect(failure.code, code);
      expect(failure.retryable, isTrue);
      expect(failure.retryAfter, retryAfter);
    });
  }

  test('a real anonymous result page (with the Cloudflare analytics beacon) '
      'is a webview result, not a challenge', () async {
    final fixture = File(
      'test/fixtures/saucenao/anonymous_result_page.html',
    ).readAsBytesSync();
    final outcome = await answer(
      http.Response.bytes(
        fixture,
        200,
        headers: {'content-type': 'text/html; charset=UTF-8'},
      ),
    );

    expect(outcome, isA<ReverseImageSearchWebView>());
    final html = (outcome as ReverseImageSearchWebView).html!;
    expect(html, contains('resulttable'));
    expect(html.toLowerCase(), contains('cloudflareinsights'));
  });

  test('decodes UTF-8 result HTML without corrupting non-ASCII text', () async {
    final outcome = await answer(_html('<html><body>结果：你好</body></html>'));

    expect(outcome, isA<ReverseImageSearchWebView>());
    expect((outcome as ReverseImageSearchWebView).html, contains('结果：你好'));
  });

  test('a no-match HTML page is an explicit empty success', () async {
    final outcome = await answer(_html('<html><body>没有匹配结果</body></html>'));

    expect(outcome, isA<ReverseImageSearchSuccess>());
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

http.Response _html(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: {'content-type': 'text/html'},
);

Future<OwnedReverseImageInput> _open(String path) {
  return OwnedReverseImageInput.open(
    path: path,
    source: ReverseImageInputSource.picker,
    mimeType: 'image/png',
    delete: (_) async {},
  );
}
