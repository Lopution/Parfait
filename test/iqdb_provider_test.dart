import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/reverse_image/image_input.dart';
import 'package:pixiv_func/core/reverse_image/iqdb_provider.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_engine.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_provider.dart';

void main() {
  late Directory tempDirectory;
  late OwnedReverseImageInput input;

  setUp(() async {
    tempDirectory = Directory.systemTemp.createTempSync('iqdb-');
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(64, 64));
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
        ..writeAsBytesSync(_webpHeader(64, 64));
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

  test('a 200 challenge page is a visible challenge failure', () async {
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
    final provider = IqdbWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchFailure>());
    expect(
      (outcome as ReverseImageSearchFailure).code,
      ReverseImageProviderFailureCode.challenge,
    );
  });

  test('a no-match page is an explicit empty success', () async {
    final client = MockClient(
      (request) async => http.Response(
        '<html><body>No relevant matches</body></html>',
        200,
        headers: {'content-type': 'text/html'},
      ),
    );
    final provider = IqdbWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchSuccess>());
    expect((outcome as ReverseImageSearchSuccess).hits, isEmpty);
  });

  test('follows a redirect inside iqdb.org only', () async {
    final client = MockClient(
      (request) async => http.Response(
        '',
        302,
        headers: {'location': 'https://iqdb.org/?status=1'},
      ),
    );
    final provider = IqdbWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchWebView>());
    expect(
      (outcome as ReverseImageSearchWebView).resultUrl.toString(),
      'https://iqdb.org/?status=1',
    );
  });

  test('rejects a redirect to a foreign host', () async {
    final client = MockClient(
      (request) async => http.Response(
        '',
        302,
        headers: {'location': 'https://evil.example/results'},
      ),
    );
    final provider = IqdbWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchFailure>());
    expect(
      (outcome as ReverseImageSearchFailure).code,
      ReverseImageProviderFailureCode.malformedResponse,
    );
  });

  test('surfaces a 429 with retry-after', () async {
    final client = MockClient(
      (request) async => http.Response('', 429, headers: {'retry-after': '12'}),
    );
    final provider = IqdbWebViewProvider(client: client);

    final outcome = await provider.search(input);

    final failure = outcome as ReverseImageSearchFailure;
    expect(failure.code, ReverseImageProviderFailureCode.rateLimited);
    expect(failure.retryAfter, const Duration(seconds: 12));
  });

  test('a non-HTML success body is a visible failure', () async {
    final client = MockClient(
      (request) async => http.Response(
        '{"error":"x"}',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final provider = IqdbWebViewProvider(client: client);

    final outcome = await provider.search(input);

    expect(
      (outcome as ReverseImageSearchFailure).code,
      ReverseImageProviderFailureCode.malformedResponse,
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

// Minimal RIFF/WEBP (VP8 lossy) header the input validator accepts: it reads
// the 9d 01 2a start code at file offset 26 and LE16 dimensions at 30/32, so
// the VP8 payload is padded accordingly (total file length must be >= 34).
List<int> _webpHeader(int width, int height) => [
  0x52, 0x49, 0x46, 0x46, // 'RIFF'
  14 & 0xff, 0, 0, 0, // RIFF size (payload + 6)
  0x57, 0x45, 0x42, 0x50, // 'WEBP'
  0x56, 0x50, 0x38, 0x20, // 'VP8 '
  14 & 0xff, 0, 0, 0, // chunk size
  0, 0, 0, 0, 0, 0, // frame tag + padding (offset 20-25)
  0x9d, 0x01, 0x2a, // start code (offset 26-28)
  0, // offset 29
  width & 0xff, (width >> 8) & 0xff, // offset 30-31
  height & 0xff, (height >> 8) & 0xff, // offset 32-33
];
