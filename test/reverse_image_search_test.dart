import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/reverse_image/image_input.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_controller.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_platform.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_provider.dart';

void main() {
  late Directory tempDirectory;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync('reverse-image-');
  });

  tearDown(() {
    if (tempDirectory.existsSync()) tempDirectory.deleteSync(recursive: true);
  });

  test('validates a real PNG header and bounded dimensions', () async {
    final file = File('${tempDirectory.path}/image.bin')
      ..writeAsBytesSync(_pngHeader(320, 240));

    final input = await OwnedReverseImageInput.open(
      path: file.path,
      source: ReverseImageInputSource.picker,
      mimeType: 'image/png',
      delete: (_) async {},
    );

    expect(input.info.format, ReverseImageFormat.png);
    expect(input.info.width, 320);
    expect(input.info.height, 240);
    expect(input.info.sizeBytes, file.lengthSync());
    await input.dispose();
  });

  test('rejects a MIME declaration that does not match the file bytes', () {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(1, 1));

    expect(
      () => OwnedReverseImageInput.open(
        path: file.path,
        source: ReverseImageInputSource.androidSend,
        mimeType: 'image/jpeg',
        delete: (_) async {},
      ),
      throwsA(
        isA<ReverseImageInputException>().having(
          (error) => error.code,
          'code',
          ReverseImageInputFailureCode.mimeMismatch,
        ),
      ),
    );
  });

  test('rejects a pixel bomb before any full image decode', () async {
    final file = File('${tempDirectory.path}/bomb.png')
      ..writeAsBytesSync(_pngHeader(100000, 100000));

    await expectLater(
      OwnedReverseImageInput.open(
        path: file.path,
        source: ReverseImageInputSource.picker,
        mimeType: 'image/png',
        delete: (_) async {},
      ),
      throwsA(
        isA<ReverseImageInputException>().having(
          (error) => error.code,
          'code',
          ReverseImageInputFailureCode.dimensionsTooLarge,
        ),
      ),
    );
  });

  test('owned input cleanup is idempotent and path-free in errors', () async {
    final deleted = <String>[];
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(1, 1));
    final input = await OwnedReverseImageInput.open(
      path: file.path,
      source: ReverseImageInputSource.picker,
      mimeType: 'image/png',
      delete: (path) async => deleted.add(path),
    );

    await input.dispose();
    await input.dispose();

    expect(deleted, [file.path]);
    expect(
      () => input.openRead(),
      throwsA(
        isA<ReverseImageInputException>()
            .having(
              (error) => error.code,
              'code',
              ReverseImageInputFailureCode.closed,
            )
            .having(
              (error) => error.message.contains(file.path),
              'path-free',
              false,
            ),
      ),
    );
  });

  test('maps, sorts and deduplicates SauceNAO-shaped Pixiv results', () {
    final result = ReverseImageResultMapper.fromSauceNaoJson({
      'results': [
        {
          'header': {'similarity': '78.2'},
          'data': {
            'pixiv_id': '42',
            'title': 'lower duplicate',
            'ext_urls': ['https://www.pixiv.net/artworks/42'],
          },
        },
        {
          'header': {'similarity': '96.4'},
          'data': {
            'pixiv_id': 42,
            'title': 'higher duplicate',
            'ext_urls': ['https://www.pixiv.net/artworks/42'],
          },
        },
        {
          'header': {'similarity': 90},
          'data': {
            'title': 'external result',
            'ext_urls': ['https://example.com/result/1'],
          },
        },
      ],
    });

    expect(result.hits, hasLength(2));
    expect(result.hits.first.pixivId, 42);
    expect(result.hits.first.similarity, 96.4);
    expect(
      result.hits.last.externalUrl.toString(),
      'https://example.com/result/1',
    );
  });

  test('rejects unsafe or malformed provider results', () {
    expect(
      () => ReverseImageResultMapper.fromSauceNaoJson({
        'results': [
          {
            'header': {'similarity': '99'},
            'data': {
              'ext_urls': ['javascript:alert(1)'],
            },
          },
        ],
      }),
      throwsA(
        isA<ReverseImageProviderException>().having(
          (error) => error.code,
          'code',
          ReverseImageProviderFailureCode.unsafeResultUrl,
        ),
      ),
    );
    expect(
      () => ReverseImageResultMapper.fromSauceNaoJson({'results': {}}),
      throwsA(isA<ReverseImageProviderException>()),
    );
  });

  test('unavailable provider is an explicit terminal failure', () async {
    final provider = UnavailableReverseImageProvider(
      reason: 'structured provider credentials and terms are not approved',
    );
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(1, 1));
    final input = await OwnedReverseImageInput.open(
      path: file.path,
      source: ReverseImageInputSource.picker,
      mimeType: 'image/png',
      delete: (_) async {},
    );

    expect(provider.capability.kind, ReverseImageProviderKind.unavailable);
    final outcome = await provider.search(input);
    expect(outcome, isA<ReverseImageSearchFailure>());
    expect(
      (outcome as ReverseImageSearchFailure).code,
      ReverseImageProviderFailureCode.providerUnavailable,
    );
    await input.dispose();
  });

  test('permission loss fails before copying the shared input', () async {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(1, 1));
    final platform = _FakeReverseImageInputPlatform(file);
    final controller = ReverseImageSearchController(
      platform: platform,
      provider: UnavailableReverseImageProvider(reason: 'not approved'),
    );
    addTearDown(controller.dispose);

    await controller.prepare(
      const ReverseImageInputReference(
        contentUri: 'content://share/1',
        mimeType: 'image/png',
        sizeBytes: 128,
        hasReadUriPermission: false,
        source: ReverseImageInputSource.androidSend,
      ),
    );

    expect(controller.state.status, ReverseImageFlowStatus.failure);
    expect(
      controller.state.failure?.code,
      ReverseImageInputFailureCode.missingReadPermission,
    );
    expect(platform.copyCount, 0);
    expect(platform.deletedPaths, isEmpty);
  });

  test('cancel and rate limit both clean the owned input', () async {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(12, 8));
    final platform = _FakeReverseImageInputPlatform(file);
    final controller = ReverseImageSearchController(
      platform: platform,
      provider: _OutcomeProvider(
        const ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.rateLimited,
          message: 'provider is rate limited',
          retryable: true,
        ),
      ),
    );
    addTearDown(controller.dispose);
    const reference = ReverseImageInputReference(
      contentUri: 'content://share/1',
      mimeType: 'image/png',
      sizeBytes: 128,
      hasReadUriPermission: true,
      source: ReverseImageInputSource.picker,
    );

    await controller.prepare(reference);
    await controller.cancel();
    expect(controller.state.status, ReverseImageFlowStatus.canceled);
    expect(platform.deletedPaths, [file.path]);

    final retryPlatform = _FakeReverseImageInputPlatform(file);
    final retryController = ReverseImageSearchController(
      platform: retryPlatform,
      provider: _OutcomeProvider(
        const ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.rateLimited,
          message: 'provider is rate limited',
          retryable: true,
        ),
      ),
    );
    addTearDown(retryController.dispose);
    await retryController.prepare(reference);
    await retryController.search();

    expect(retryController.state.status, ReverseImageFlowStatus.failure);
    expect(
      retryController.state.failure?.code,
      ReverseImageProviderFailureCode.rateLimited,
    );
    expect(retryController.state.failure?.retryable, isTrue);
    expect(retryPlatform.deletedPaths, [file.path]);
  });

  test(
    'picker and SEND references share preparation and terminal cleanup',
    () async {
      final file = File('${tempDirectory.path}/image.png')
        ..writeAsBytesSync(_pngHeader(12, 8));
      final platform = _FakeReverseImageInputPlatform(file);
      final controller = ReverseImageSearchController(
        platform: platform,
        provider: UnavailableReverseImageProvider(reason: 'not approved'),
      );
      addTearDown(controller.dispose);
      const reference = ReverseImageInputReference(
        contentUri: 'content://share/1',
        mimeType: 'image/png',
        sizeBytes: 128,
        hasReadUriPermission: true,
        source: ReverseImageInputSource.androidSend,
      );

      await controller.prepare(reference);
      expect(controller.state.status, ReverseImageFlowStatus.ready);
      await controller.search();
      expect(controller.state.status, ReverseImageFlowStatus.failure);
      expect(
        controller.state.failure?.code,
        ReverseImageProviderFailureCode.providerUnavailable,
      );
      expect(platform.deletedPaths, [file.path]);
    },
  );
}

class _FakeReverseImageInputPlatform implements ReverseImageInputPlatform {
  _FakeReverseImageInputPlatform(this.file);

  final File file;
  final deletedPaths = <String>[];
  int copyCount = 0;

  @override
  Future<String> copyToOwnedFile(ReverseImageInputReference reference) async {
    copyCount++;
    return file.path;
  }

  @override
  Future<void> deleteOwnedFile(String path) async => deletedPaths.add(path);

  @override
  Future<ReverseImageInputReference?> pickImage() async => null;
}

class _OutcomeProvider implements ReverseImageProvider {
  const _OutcomeProvider(this.outcome);

  final ReverseImageSearchOutcome outcome;

  @override
  ReverseImageProviderCapability get capability =>
      const ReverseImageProviderCapability(
        name: 'test-provider',
        kind: ReverseImageProviderKind.structuredApi,
        enabled: true,
        observedAt: 'test',
        reason: 'test-only provider',
      );

  @override
  Future<ReverseImageSearchOutcome> search(
    OwnedReverseImageInput input, {
    CancelToken? cancelToken,
  }) async => outcome;
}

Uint8List _pngHeader(int width, int height) {
  final bytes = BytesBuilder();
  bytes.add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  bytes.add(_be32(13));
  bytes.add(const [0x49, 0x48, 0x44, 0x52]);
  bytes.add(_be32(width));
  bytes.add(_be32(height));
  bytes.add(const [8, 6, 0, 0, 0]);
  bytes.add(const [0, 0, 0, 0]);
  return bytes.takeBytes();
}

List<int> _be32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];
