import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/reverse_image/image_input.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_controller.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_engine.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_platform.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_provider.dart';

ReverseImageFlowState _stateOf(
  ProviderContainer container,
  ReverseImageSearchSession session,
) => container.read(reverseImageSearchControllerProvider(session));

ProviderContainer _flowContainer(ReverseImageSearchSession session) {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  // Keep the autoDispose family member alive for the whole test: a bare
  // container.read would dispose it at the first await gap and reset state.
  final sub = container.listen(
    reverseImageSearchControllerProvider(session),
    (_, _) {},
  );
  addTearDown(sub.close);
  return container;
}

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
      () => ReverseImageResultMapper.fromSauceNaoJson({
        'results': <String, Object?>{},
      }),
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
    final sessionController = ReverseImageSearchSession.single(
      platform: platform,
      provider: UnavailableReverseImageProvider(reason: 'not approved'),
    );
    final containerController = _flowContainer(sessionController);
    final controller = containerController.read(
      reverseImageSearchControllerProvider(sessionController).notifier,
    );

    await controller.prepare(
      const ReverseImageInputReference(
        contentUri: 'content://share/1',
        mimeType: 'image/png',
        sizeBytes: 128,
        hasReadUriPermission: false,
        source: ReverseImageInputSource.androidSend,
      ),
    );

    expect(
      _stateOf(containerController, sessionController).status,
      ReverseImageFlowStatus.failure,
    );
    expect(
      _stateOf(containerController, sessionController).failure?.code,
      ReverseImageInputFailureCode.missingReadPermission,
    );
    expect(platform.copyCount, 0);
    expect(platform.deletedPaths, isEmpty);
  });

  test('cancel and rate limit both clean the owned input', () async {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(12, 8));
    final platform = _FakeReverseImageInputPlatform(file);
    final sessionController = ReverseImageSearchSession.single(
      platform: platform,
      provider: _OutcomeProvider(
        const ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.rateLimited,
          message: 'provider is rate limited',
          retryable: true,
        ),
      ),
    );
    final containerController = _flowContainer(sessionController);
    final controller = containerController.read(
      reverseImageSearchControllerProvider(sessionController).notifier,
    );
    const reference = ReverseImageInputReference(
      contentUri: 'content://share/1',
      mimeType: 'image/png',
      sizeBytes: 128,
      hasReadUriPermission: true,
      source: ReverseImageInputSource.picker,
    );

    await controller.prepare(reference);
    await controller.cancel();
    expect(
      _stateOf(containerController, sessionController).status,
      ReverseImageFlowStatus.canceled,
    );
    expect(platform.deletedPaths, [file.path]);

    final retryPlatform = _FakeReverseImageInputPlatform(file);
    final sessionRetryController = ReverseImageSearchSession.single(
      platform: retryPlatform,
      provider: _OutcomeProvider(
        const ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.rateLimited,
          message: 'provider is rate limited',
          retryable: true,
        ),
      ),
    );
    final containerRetryController = _flowContainer(sessionRetryController);
    final retryController = containerRetryController.read(
      reverseImageSearchControllerProvider(sessionRetryController).notifier,
    );
    await retryController.prepare(reference);
    await retryController.search();

    expect(
      _stateOf(containerRetryController, sessionRetryController).status,
      ReverseImageFlowStatus.failure,
    );
    expect(
      _stateOf(containerRetryController, sessionRetryController).failure?.code,
      ReverseImageProviderFailureCode.rateLimited,
    );
    expect(
      _stateOf(
        containerRetryController,
        sessionRetryController,
      ).failure?.retryable,
      isTrue,
    );
    // The image is kept across an engine failure so the user can retry or
    // switch engines; cancel still cleans it up.
    expect(retryPlatform.deletedPaths, isEmpty);
    await retryController.cancel();
    expect(retryPlatform.deletedPaths, [file.path]);
  });

  test('rate-limit retryAfter is preserved on the flow failure', () async {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(12, 8));
    final platform = _FakeReverseImageInputPlatform(file);
    final sessionController = ReverseImageSearchSession.single(
      platform: platform,
      provider: _OutcomeProvider(
        const ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.rateLimited,
          message: 'provider is rate limited',
          retryable: true,
          retryAfter: Duration(seconds: 27),
        ),
      ),
    );
    final containerController = _flowContainer(sessionController);
    final controller = containerController.read(
      reverseImageSearchControllerProvider(sessionController).notifier,
    );
    const reference = ReverseImageInputReference(
      contentUri: 'content://share/1',
      mimeType: 'image/png',
      sizeBytes: 128,
      hasReadUriPermission: true,
      source: ReverseImageInputSource.picker,
    );

    await controller.prepare(reference);
    await controller.search();

    expect(
      _stateOf(containerController, sessionController).status,
      ReverseImageFlowStatus.failure,
    );
    expect(
      _stateOf(containerController, sessionController).failure?.code,
      ReverseImageProviderFailureCode.rateLimited,
    );
    expect(
      _stateOf(containerController, sessionController).failure?.retryAfter,
      const Duration(seconds: 27),
    );
    // Failure keeps the owned input so the same image can retry elsewhere.
    expect(platform.deletedPaths, isEmpty);
  });

  test('webview success releases the owned input exactly once', () async {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(12, 8));
    final platform = _FakeReverseImageInputPlatform(file);
    final sessionController = ReverseImageSearchSession.single(
      platform: platform,
      provider: _OutcomeProvider(
        const ReverseImageSearchWebView(
          html: '<html><body>results</body></html>',
          observedAt: 'test',
        ),
      ),
    );
    final containerController = _flowContainer(sessionController);
    final controller = containerController.read(
      reverseImageSearchControllerProvider(sessionController).notifier,
    );
    const reference = ReverseImageInputReference(
      contentUri: 'content://share/1',
      mimeType: 'image/png',
      sizeBytes: 128,
      hasReadUriPermission: true,
      source: ReverseImageInputSource.picker,
    );

    await controller.prepare(reference);
    await controller.search();

    expect(
      _stateOf(containerController, sessionController).status,
      ReverseImageFlowStatus.success,
    );
    expect(_stateOf(containerController, sessionController).webView, isNotNull);
    expect(platform.deletedPaths, [file.path]);
  });

  test(
    'picker and SEND references share preparation and terminal cleanup',
    () async {
      final file = File('${tempDirectory.path}/image.png')
        ..writeAsBytesSync(_pngHeader(12, 8));
      final platform = _FakeReverseImageInputPlatform(file);
      final sessionController = ReverseImageSearchSession.single(
        platform: platform,
        provider: UnavailableReverseImageProvider(reason: 'not approved'),
      );
      final containerController = _flowContainer(sessionController);
      final controller = containerController.read(
        reverseImageSearchControllerProvider(sessionController).notifier,
      );
      const reference = ReverseImageInputReference(
        contentUri: 'content://share/1',
        mimeType: 'image/png',
        sizeBytes: 128,
        hasReadUriPermission: true,
        source: ReverseImageInputSource.androidSend,
      );

      await controller.prepare(reference);
      expect(
        _stateOf(containerController, sessionController).status,
        ReverseImageFlowStatus.ready,
      );
      await controller.search();
      expect(
        _stateOf(containerController, sessionController).status,
        ReverseImageFlowStatus.failure,
      );
      expect(
        _stateOf(containerController, sessionController).failure?.code,
        ReverseImageProviderFailureCode.providerUnavailable,
      );
      // Failure keeps the image; the owned file is released on dispose.
      expect(platform.deletedPaths, isEmpty);
    },
  );

  test('a failed engine keeps the input and switches to another', () async {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(12, 8));
    final platform = _FakeReverseImageInputPlatform(file);
    final failing = _OutcomeProvider(
      const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.challenge,
        message: 'challenged',
      ),
    );
    final succeeding = _OutcomeProvider(
      const ReverseImageSearchSuccess([
        ReverseImageHit(similarity: 90, pixivId: 42),
      ]),
    );
    final session = ReverseImageSearchSession(
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: failing,
        ReverseImageEngine.iqdb: succeeding,
      },
    );
    final container = _flowContainer(session);
    final controller = container.read(
      reverseImageSearchControllerProvider(session).notifier,
    );
    const reference = ReverseImageInputReference(
      contentUri: 'content://share/1',
      mimeType: 'image/png',
      sizeBytes: 128,
      hasReadUriPermission: true,
      source: ReverseImageInputSource.picker,
    );

    await controller.prepare(reference);
    await controller.search();
    var state = _stateOf(container, session);
    expect(state.status, ReverseImageFlowStatus.failure);
    expect(state.engine, ReverseImageEngine.sauceNao);
    expect(state.input, isNotNull);
    expect(
      state.engineFailures[ReverseImageEngine.sauceNao]?.code,
      ReverseImageProviderFailureCode.challenge,
    );
    expect(platform.deletedPaths, isEmpty);

    await controller.selectEngine(ReverseImageEngine.iqdb);
    state = _stateOf(container, session);
    expect(state.status, ReverseImageFlowStatus.ready);
    expect(state.engine, ReverseImageEngine.iqdb);

    await controller.search();
    state = _stateOf(container, session);
    expect(state.status, ReverseImageFlowStatus.success);
    expect(state.results.single.pixivId, 42);
    expect(state.engineFailures, contains(ReverseImageEngine.sauceNao));
  });

  test('selectEngine is a no-op without a held image', () async {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(12, 8));
    final platform = _FakeReverseImageInputPlatform(file);
    final session = ReverseImageSearchSession(
      platform: platform,
      providers: const {},
    );
    final container = _flowContainer(session);
    final controller = container.read(
      reverseImageSearchControllerProvider(session).notifier,
    );

    await controller.selectEngine(ReverseImageEngine.iqdb);
    expect(_stateOf(container, session).engine, ReverseImageEngine.sauceNao);
  });

  test(
    'a missing engine in the map is an explicit unavailable failure',
    () async {
      final file = File('${tempDirectory.path}/image.png')
        ..writeAsBytesSync(_pngHeader(12, 8));
      final platform = _FakeReverseImageInputPlatform(file);
      final session = ReverseImageSearchSession(
        platform: platform,
        providers: {
          ReverseImageEngine.sauceNao: _OutcomeProvider(
            const ReverseImageSearchSuccess([]),
          ),
        },
      );
      final container = _flowContainer(session);
      final controller = container.read(
        reverseImageSearchControllerProvider(session).notifier,
      );
      await controller.prepare(
        const ReverseImageInputReference(
          contentUri: 'content://share/1',
          mimeType: 'image/png',
          sizeBytes: 128,
          hasReadUriPermission: true,
          source: ReverseImageInputSource.picker,
        ),
      );

      await controller.selectEngine(ReverseImageEngine.ascii2d);
      await controller.search();

      final state = _stateOf(container, session);
      expect(state.status, ReverseImageFlowStatus.failure);
      expect(
        state.failure?.code,
        ReverseImageProviderFailureCode.providerUnavailable,
      );
      expect(state.engineFailures, contains(ReverseImageEngine.ascii2d));
    },
  );

  test('a web-upload outcome arms the file and keeps it owned', () async {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(_pngHeader(12, 8));
    final platform = _FakeReverseImageInputPlatform(file);
    final armer = _RecordingUploadArmer();
    final session = ReverseImageSearchSession.single(
      platform: platform,
      provider: _OutcomeProvider(
        ReverseImageSearchWebUpload(
          engine: ReverseImageEngine.ascii2d,
          uploadPageUrl: Uri.parse('https://ascii2d.net/'),
          imagePath: 'placeholder',
          imageMimeType: 'image/png',
          observedAt: 'test',
        ),
      ),
      initialEngine: ReverseImageEngine.ascii2d,
      uploadArmer: armer,
    );
    final container = _flowContainer(session);
    final controller = container.read(
      reverseImageSearchControllerProvider(session).notifier,
    );
    await controller.prepare(
      const ReverseImageInputReference(
        contentUri: 'content://share/1',
        mimeType: 'image/png',
        sizeBytes: 128,
        hasReadUriPermission: true,
        source: ReverseImageInputSource.picker,
      ),
    );
    await controller.search();

    final state = _stateOf(container, session);
    expect(state.status, ReverseImageFlowStatus.success);
    expect(armer.armedPaths, [file.path]);
    expect(state.webUpload?.armedUri, 'content://armed/1');
    // The browser submits the file later — it stays owned for now.
    expect(platform.deletedPaths, isEmpty);

    // Leaving the upload result releases the input and disarms the slot.
    await controller.selectEngine(ReverseImageEngine.sauceNao);
    expect(armer.disarmCount, greaterThanOrEqualTo(1));
  });

  test(
    'an arming failure is a visible engine failure keeping the input',
    () async {
      final file = File('${tempDirectory.path}/image.png')
        ..writeAsBytesSync(_pngHeader(12, 8));
      final platform = _FakeReverseImageInputPlatform(file);
      final armer = _RecordingUploadArmer(failArm: true);
      final session = ReverseImageSearchSession.single(
        platform: platform,
        provider: _OutcomeProvider(
          ReverseImageSearchWebUpload(
            engine: ReverseImageEngine.tinEye,
            uploadPageUrl: Uri.parse('https://tineye.com/'),
            imagePath: 'placeholder',
            imageMimeType: 'image/png',
            observedAt: 'test',
          ),
        ),
        initialEngine: ReverseImageEngine.tinEye,
        uploadArmer: armer,
      );
      final container = _flowContainer(session);
      final controller = container.read(
        reverseImageSearchControllerProvider(session).notifier,
      );
      await controller.prepare(
        const ReverseImageInputReference(
          contentUri: 'content://share/1',
          mimeType: 'image/png',
          sizeBytes: 128,
          hasReadUriPermission: true,
          source: ReverseImageInputSource.picker,
        ),
      );
      await controller.search();

      final state = _stateOf(container, session);
      expect(state.status, ReverseImageFlowStatus.failure);
      expect(state.engine, ReverseImageEngine.tinEye);
      expect(state.engineFailures, contains(ReverseImageEngine.tinEye));
      expect(platform.deletedPaths, isEmpty);
    },
  );
}

class _RecordingUploadArmer implements ReverseImageUploadArmer {
  _RecordingUploadArmer({this.failArm = false});

  final bool failArm;
  final armedPaths = <String>[];
  var disarmCount = 0;

  @override
  Future<String?> armUpload(String path) async {
    if (failArm) {
      throw const ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.unavailable,
        'arm unavailable',
      );
    }
    armedPaths.add(path);
    return 'content://armed/${armedPaths.length}';
  }

  @override
  Future<void> disarmUpload() async {
    disarmCount += 1;
  }
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
