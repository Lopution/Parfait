import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/reverse_image/image_input.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_engine.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_provider.dart';
import 'package:pixiv_func/core/reverse_image/webview_upload_provider.dart';

void main() {
  late Directory tempDirectory;
  late OwnedReverseImageInput input;

  setUp(() async {
    tempDirectory = Directory.systemTemp.createTempSync('web-upload-');
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(64, 64));
    input = await OwnedReverseImageInput.open(
      path: file.path,
      source: ReverseImageInputSource.picker,
      mimeType: 'image/png',
      delete: (_) async {},
    );
  });

  tearDown(() async {
    await input.dispose();
    if (tempDirectory.existsSync()) tempDirectory.deleteSync(recursive: true);
  });

  test('returns a web upload outcome carrying the owned input path', () async {
    final provider = WebViewUploadProvider(
      spec: ReverseImageEngineSpecs.ascii2d,
      now: () => DateTime.utc(2026, 9, 16),
    );

    final outcome = await provider.search(input);

    expect(outcome, isA<ReverseImageSearchWebUpload>());
    final upload = outcome as ReverseImageSearchWebUpload;
    expect(upload.engine, ReverseImageEngine.ascii2d);
    expect(upload.uploadPageUrl.toString(), 'https://ascii2d.net/');
    expect(upload.imagePath, input.info.path);
    expect(upload.imageMimeType, 'image/png');
    expect(upload.observedAt, '2026-09-16T00:00:00.000Z');
  });

  test('tineye descriptor points at tineye.com', () async {
    final provider = WebViewUploadProvider(
      spec: ReverseImageEngineSpecs.tinEye,
    );

    final outcome = await provider.search(input);

    final upload = outcome as ReverseImageSearchWebUpload;
    expect(upload.engine, ReverseImageEngine.tinEye);
    expect(upload.uploadPageUrl.toString(), 'https://tineye.com/');
  });

  test(
    'an input outside engine constraints fails fast as unsupportedInput',
    () async {
      final tiny = ReverseImageEngineSpec(
        engine: ReverseImageEngine.ascii2d,
        displayName: 'Ascii2D',
        transport: ReverseImageTransport.webViewUpload,
        uploadPageUrl: 'https://ascii2d.net/',
        webViewHosts: const {'ascii2d.net'},
        maxBytes: 1,
      );
      final constrained = WebViewUploadProvider(spec: tiny);

      final outcome = await constrained.search(input);

      expect(
        (outcome as ReverseImageSearchFailure).code,
        ReverseImageProviderFailureCode.unsupportedInput,
      );
    },
  );

  test('a cancelled search reports cancellation', () async {
    final provider = WebViewUploadProvider(
      spec: ReverseImageEngineSpecs.ascii2d,
    );
    final token = CancelToken()..cancel();

    final outcome = await provider.search(input, cancelToken: token);

    expect(
      (outcome as ReverseImageSearchFailure).code,
      ReverseImageProviderFailureCode.cancelled,
    );
  });

  test('capability is interactiveWebView and enabled', () {
    final provider = WebViewUploadProvider(
      spec: ReverseImageEngineSpecs.tinEye,
    );
    expect(
      provider.capability.kind,
      ReverseImageProviderKind.interactiveWebView,
    );
    expect(provider.capability.enabled, isTrue);
  });
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
