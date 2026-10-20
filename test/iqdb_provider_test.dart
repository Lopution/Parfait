import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/reverse_image/image_input.dart';
import 'package:parfait/core/reverse_image/iqdb_provider.dart';
import 'package:parfait/core/reverse_image/reverse_image_engine.dart';
import 'package:parfait/core/reverse_image/reverse_image_provider.dart';
import 'helpers/image_headers.dart';

void main() {
  late Directory tempDirectory;
  late OwnedReverseImageInput input;

  setUp(() async {
    tempDirectory = Directory.systemTemp.createTempSync('iqdb-');
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(pngHeader(64, 64));
    input = await _open(file.path, 'image/png');
  });

  tearDown(() async {
    await input.dispose();
    if (tempDirectory.existsSync()) tempDirectory.deleteSync(recursive: true);
  });

  test(
    'posts a multipart file to iqdb.org and returns the result html',
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
          '<html><body><table><th>Best match</th></table></body></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });
      final provider = IqdbWebViewProvider(client: client);

      final outcome = await provider.search(input);

      expect(method, 'POST');
      expect(url, 'https://iqdb.org/');
      expect(contentType, contains('multipart/form-data'));
      expect(body, contains('name="file"'));
      expect(outcome, isA<ReverseImageSearchWebView>());
      final webView = outcome as ReverseImageSearchWebView;
      expect(webView.html, contains('Best match'));
      expect(webView.resultUrl, isNull);
    },
  );

  test(
    'rejects an input outside IQDB constraints without sending a request',
    () async {
      var requested = false;
      final client = MockClient((request) async {
        requested = true;
        return http.Response('', 200);
      });
      final provider = IqdbWebViewProvider(client: client);
      // IQDB documents JPEG/PNG/GIF only; webp is valid globally but not here.
      final webp = File('${tempDirectory.path}/image.webp')
        ..writeAsBytesSync(webpHeader(64, 64));
      final webpInput = await _open(webp.path, 'image/webp');
      addTearDown(webpInput.dispose);

      final outcome = await provider.search(webpInput);

      expect(outcome, isA<ReverseImageSearchFailure>());
      expect(
        (outcome as ReverseImageSearchFailure).code,
        ReverseImageProviderFailureCode.unsupportedInput,
      );
      expect(requested, isFalse);
    },
  );

  test('spec marks webp and oversized inputs as unsupported', () {
    const spec = ReverseImageEngineSpecs.iqdb;
    final webpInfo = _info(mimeType: 'image/webp');
    expect(spec.supportsInput(webpInfo), isFalse);
    final huge = _info(mimeType: 'image/png', sizeBytes: 9 * 1024 * 1024);
    expect(spec.supportsInput(huge), isFalse);
    final wide = _info(mimeType: 'image/png', width: 7501);
    expect(spec.supportsInput(wide), isFalse);
    final ok = _info(mimeType: 'image/jpeg', sizeBytes: 1024, width: 800);
    expect(spec.supportsInput(ok), isTrue);
  });

  Future<ReverseImageSearchOutcome> answer(http.Response response) =>
      IqdbWebViewProvider(
        client: MockClient((_) async => response),
      ).search(input);

  test('each bad answer is a visible failure with its code', () async {
    const challenge =
        '<!DOCTYPE html><html><head>'
        '<title>Just a moment...</title></head><body>'
        '<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1">'
        '</script></body></html>';
    for (final (response, code) in [
      (http.Response(challenge, 200, headers: _html), _Code.challenge),
      (_redirect('https://evil.example/results'), _Code.malformedResponse),
      (
        http.Response('{"error":"x"}', 200, headers: _json),
        _Code.malformedResponse,
      ),
      (
        http.Response('', 429, headers: {'retry-after': '12'}),
        _Code.rateLimited,
      ),
    ]) {
      final failure = await answer(response) as ReverseImageSearchFailure;
      expect(failure.code, code, reason: response.body);
      if (code == _Code.rateLimited) {
        expect(failure.retryAfter, const Duration(seconds: 12));
      }
    }
  });

  test('a no-match page is an explicit empty success', () async {
    final outcome = await answer(
      http.Response(
        '<html><body>No relevant matches</body></html>',
        200,
        headers: _html,
      ),
    );
    expect(outcome, isA<ReverseImageSearchSuccess>());
  });

  test('follows a redirect inside iqdb.org only', () async {
    final outcome = await answer(_redirect('https://iqdb.org/?status=1'));
    expect(
      (outcome as ReverseImageSearchWebView).resultUrl.toString(),
      'https://iqdb.org/?status=1',
    );
  });

  test('provider capability is interactiveWebView and enabled', () {
    final provider = IqdbWebViewProvider(
      client: MockClient((_) async => http.Response('', 503)),
    );
    expect(
      provider.capability.kind,
      ReverseImageProviderKind.interactiveWebView,
    );
    expect(provider.capability.enabled, isTrue);
  });

  test('a cancelled search reports cancellation', () async {
    final client = MockClient(
      (request) async => http.Response('<html>late</html>', 200),
    );
    final provider = IqdbWebViewProvider(client: client);
    final token = CancelToken()..cancel();

    final outcome = await provider.search(input, cancelToken: token);

    expect(
      (outcome as ReverseImageSearchFailure).code,
      ReverseImageProviderFailureCode.cancelled,
    );
  });
}

typedef _Code = ReverseImageProviderFailureCode;

const _html = {'content-type': 'text/html'};
const _json = {'content-type': 'application/json'};

http.Response _redirect(String location) =>
    http.Response('', 302, headers: {'location': location});

Future<OwnedReverseImageInput> _open(String path, String mimeType) {
  return OwnedReverseImageInput.open(
    path: path,
    source: ReverseImageInputSource.picker,
    mimeType: mimeType,
    delete: (_) async {},
  );
}

ReverseImageInputInfo _info({
  required String mimeType,
  int sizeBytes = 100,
  int width = 64,
  int height = 64,
}) => ReverseImageInputInfo(
  path: '/tmp/x',
  source: ReverseImageInputSource.picker,
  mimeType: mimeType,
  sizeBytes: sizeBytes,
  format: ReverseImageFormat.png,
  width: width,
  height: height,
);
