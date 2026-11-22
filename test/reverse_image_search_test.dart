import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:parfait/core/platform/shared_image.dart';
import 'package:parfait/core/reverse_image/desktop_image_input.dart';
import 'package:parfait/core/reverse_image/image_input.dart';
import 'package:parfait/core/reverse_image/reverse_image_controller.dart';
import 'package:parfait/core/reverse_image/reverse_image_engine.dart';
import 'package:parfait/core/reverse_image/reverse_image_external.dart';
import 'package:parfait/core/reverse_image/reverse_image_html_parser.dart';
import 'package:parfait/core/reverse_image/reverse_image_navigation_policy.dart';
import 'package:parfait/core/reverse_image/reverse_image_platform.dart';
import 'package:parfait/core/reverse_image/reverse_image_provider.dart';
import 'helpers/image_headers.dart';
import 'helpers/reverse_image_world.dart' show OutcomeReverseImageProvider;

const _picked = ReverseImageInputReference(
  contentUri: 'content://share/1',
  mimeType: 'image/png',
  sizeBytes: 128,
  hasReadUriPermission: true,
  source: ReverseImageInputSource.picker,
);

/// [session]'s flow controller, kept alive for the whole test.
ReverseImageSearchController _flowController(
  ReverseImageSearchSession session,
) {
  final container = ProviderContainer.test();
  final provider = reverseImageSearchControllerProvider(session);
  // Keep the autoDispose family member alive for the whole test: a bare
  // container.read would dispose it at the first await gap and reset state.
  final sub = container.listen(provider, (_, _) {});
  addTearDown(sub.close);
  return container.read(provider.notifier);
}

void main() {
  late Directory tempDirectory;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync('reverse-image-');
  });

  // A single-engine flow over a 12×8 PNG in the temp directory.
  (ReverseImageSearchController, _FakeReverseImageInputPlatform, File) flowOver(
    ReverseImageProvider provider,
  ) {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(pngHeader(12, 8));
    final platform = _FakeReverseImageInputPlatform(file);
    final controller = _flowController(
      ReverseImageSearchSession.single(platform: platform, provider: provider),
    );
    return (controller, platform, file);
  }

  tearDown(() {
    if (tempDirectory.existsSync()) tempDirectory.deleteSync(recursive: true);
  });

  test('reads the format and size; EXIF cannot push a JPEG frame out of '
      'reach', () async {
    final jpeg = img.encodeJpg(img.Image(width: 30, height: 20));
    // A maximal APP1 segment, twice: the frame header lands past 128 KiB.
    final app1 = [0xff, 0xe1, 0xff, 0xff, ...List.filled(0xfffd, 0)];
    for (final (bytes, mime, format, width, height) in [
      (pngHeader(320, 240), 'image/png', ReverseImageFormat.png, 320, 240),
      (
        [0xff, 0xd8, ...app1, ...app1, ...jpeg.skip(2)],
        'image/jpeg',
        ReverseImageFormat.jpeg,
        30,
        20,
      ),
    ]) {
      final file = File('${tempDirectory.path}/image.bin')
        ..writeAsBytesSync(bytes);
      final input = await OwnedReverseImageInput.open(
        path: file.path,
        source: ReverseImageInputSource.picker,
        mimeType: mime,
        delete: (_) async {},
      );

      final info = input.info;
      expect((info.format, info.width, info.height), (format, width, height));
      expect(info.sizeBytes, file.lengthSync());
      await input.dispose();
    }
  });

  test('rejects a MIME declaration that does not match the file bytes', () {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(pngHeader(1, 1));

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
      ..writeAsBytesSync(pngHeader(100000, 100000));

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
      ..writeAsBytesSync(pngHeader(1, 1));
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

  test('unavailable provider is an explicit terminal failure', () async {
    final provider = UnavailableReverseImageProvider(
      reason: 'structured provider credentials and terms are not approved',
    );
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(pngHeader(1, 1));
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
      ..writeAsBytesSync(pngHeader(1, 1));
    final platform = _FakeReverseImageInputPlatform(file);
    final sessionController = ReverseImageSearchSession.single(
      platform: platform,
      provider: UnavailableReverseImageProvider(reason: 'not approved'),
    );
    final controller = _flowController(sessionController);

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
    const rateLimited = ReverseImageSearchFailure(
      code: ReverseImageProviderFailureCode.rateLimited,
      message: 'provider is rate limited',
      retryable: true,
    );
    final (controller, platform, file) = flowOver(
      OutcomeReverseImageProvider(rateLimited),
    );

    await controller.prepare(_picked);
    await controller.cancel();
    expect(controller.state.status, ReverseImageFlowStatus.canceled);
    expect(platform.deletedPaths, [file.path]);

    final (retryController, retryPlatform, _) = flowOver(
      OutcomeReverseImageProvider(rateLimited),
    );
    await retryController.prepare(_picked);
    await retryController.search();

    final failed = retryController.state;
    expect(failed.status, ReverseImageFlowStatus.failure);
    expect(failed.failure?.code, ReverseImageProviderFailureCode.rateLimited);
    expect(failed.failure?.retryable, isTrue);
    // The image is kept across an engine failure so the user can retry or
    // switch engines; cancel still cleans it up.
    expect(retryPlatform.deletedPaths, isEmpty);
    await retryController.cancel();
    expect(retryPlatform.deletedPaths, [file.path]);
  });

  test('rate-limit retryAfter is preserved on the flow failure', () async {
    final (controller, platform, file) = flowOver(
      OutcomeReverseImageProvider(
        const ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.rateLimited,
          message: 'provider is rate limited',
          retryable: true,
          retryAfter: Duration(seconds: 27),
        ),
      ),
    );

    await controller.prepare(_picked);
    await controller.search();

    expect(controller.state.status, ReverseImageFlowStatus.failure);
    expect(
      controller.state.failure?.code,
      ReverseImageProviderFailureCode.rateLimited,
    );
    expect(controller.state.failure?.retryAfter, const Duration(seconds: 27));
    // Failure keeps the owned input so the same image can retry elsewhere.
    expect(platform.deletedPaths, isEmpty);
  });

  test('a webview success keeps the image until the flow ends', () async {
    final (controller, platform, file) = flowOver(
      OutcomeReverseImageProvider(
        const ReverseImageSearchWebView(
          html: '<html><body>results</body></html>',
          observedAt: 'test',
        ),
      ),
    );

    await controller.prepare(_picked);
    await controller.search();

    expect(controller.state.status, ReverseImageFlowStatus.success);
    expect(controller.state.webView, isNotNull);
    // Kept for another engine; released exactly once when the flow ends.
    expect(controller.state.input, isNotNull);
    expect(platform.deletedPaths, isEmpty);
    await controller.cancel();
    await controller.cancel();
    expect(platform.deletedPaths, [file.path]);
  });

  test(
    'picker and SEND references share preparation and terminal cleanup',
    () async {
      final (controller, platform, file) = flowOver(
        UnavailableReverseImageProvider(reason: 'not approved'),
      );
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
      // Failure keeps the image; the owned file is released on dispose.
      expect(platform.deletedPaths, isEmpty);
    },
  );

  test(
    'picker accepts local paths on desktop/iOS while androidSend rejects them',
    () async {
      final (controller, _, _) = flowOver(
        OutcomeReverseImageProvider(const ReverseImageSearchSuccess()),
      );
      for (final path in [
        '/tmp/sample.png',
        'file:///tmp/sample.png',
        r'C:\Users\demo\sample.png',
      ]) {
        await controller.prepare(
          ReverseImageInputReference(
            contentUri: path,
            mimeType: 'image/png',
            sizeBytes: 128,
            hasReadUriPermission: true,
            source: ReverseImageInputSource.picker,
          ),
        );
        expect(controller.state.status, ReverseImageFlowStatus.ready);
      }

      await controller.prepare(
        const ReverseImageInputReference(
          contentUri: '/tmp/sample.png',
          mimeType: 'image/png',
          sizeBytes: 128,
          hasReadUriPermission: true,
          source: ReverseImageInputSource.androidSend,
        ),
      );
      expect(controller.state.status, ReverseImageFlowStatus.failure);
      expect(
        controller.state.failure?.code,
        ReverseImageInputFailureCode.invalidReference,
      );
    },
  );

  test('a failed engine keeps the input and switches to another', () async {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(pngHeader(12, 8));
    final platform = _FakeReverseImageInputPlatform(file);
    final failing = OutcomeReverseImageProvider(
      const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.challenge,
        message: 'challenged',
      ),
    );
    final succeeding = OutcomeReverseImageProvider(
      const ReverseImageSearchSuccess(),
    );
    final session = ReverseImageSearchSession(
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: failing,
        ReverseImageEngine.iqdb: succeeding,
      },
    );
    final controller = _flowController(session);

    await controller.prepare(_picked);
    await controller.search();
    var state = controller.state;
    expect(state.status, ReverseImageFlowStatus.failure);
    expect(state.engine, ReverseImageEngine.sauceNao);
    expect(state.input, isNotNull);
    expect(
      state.engineFailures[ReverseImageEngine.sauceNao]?.code,
      ReverseImageProviderFailureCode.challenge,
    );
    expect(platform.deletedPaths, isEmpty);

    await controller.selectEngine(ReverseImageEngine.iqdb);
    state = controller.state;
    expect(state.status, ReverseImageFlowStatus.ready);
    expect(state.engine, ReverseImageEngine.iqdb);

    await controller.search();
    state = controller.state;
    expect(state.status, ReverseImageFlowStatus.success);
    // A no-match keeps the image so a third engine can still be tried.
    expect(state.input, isNotNull);
    expect(platform.deletedPaths, isEmpty);
    expect(state.engineFailures, contains(ReverseImageEngine.sauceNao));
    expect(state.noMatchEngines, {ReverseImageEngine.iqdb});

    // Another image, then the picker is cancelled: the page is as it was.
    await controller.pick();
    expect(controller.state, same(state));
  });

  test('the next engine skips failed, empty and unfit engines', () async {
    // WebP: IQDB does not take it.
    final file = File('${tempDirectory.path}/image.webp')
      ..writeAsBytesSync(_webpHeader(12, 8));
    final platform = _FakeReverseImageInputPlatform(file);
    final session = ReverseImageSearchSession(
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: OutcomeReverseImageProvider(
          const ReverseImageSearchSuccess(),
        ),
        ReverseImageEngine.ascii2d: OutcomeReverseImageProvider(
          const ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.network,
            message: 'offline',
          ),
        ),
        ReverseImageEngine.tinEye: OutcomeReverseImageProvider(
          const ReverseImageSearchSuccess(),
        ),
      },
    );
    final controller = _flowController(session);
    await controller.prepare(
      const ReverseImageInputReference(
        contentUri: 'content://share/1',
        mimeType: 'image/webp',
        sizeBytes: 128,
        hasReadUriPermission: true,
        source: ReverseImageInputSource.picker,
      ),
    );
    expect(controller.state.nextEngine, ReverseImageEngine.ascii2d);

    await controller.search();
    // SauceNAO came back empty; IQDB cannot take WebP.
    expect(controller.state.nextEngine, ReverseImageEngine.ascii2d);
    await controller.searchNextEngine();
    var state = controller.state;
    expect(state.engine, ReverseImageEngine.ascii2d);
    expect(state.status, ReverseImageFlowStatus.failure);
    expect(state.nextEngine, ReverseImageEngine.tinEye);

    await controller.searchNextEngine();
    state = controller.state;
    expect(state.engine, ReverseImageEngine.tinEye);
    expect(state.noMatchEngines, {
      ReverseImageEngine.sauceNao,
      ReverseImageEngine.tinEye,
    });
    expect(state.nextEngine, isNull);
  });

  test(
    'a challenge falls back to the engine upload form in the browser',
    () async {
      final file = File('${tempDirectory.path}/image.png')
        ..writeAsBytesSync(pngHeader(12, 8));
      final platform = _FakeReverseImageInputPlatform(file);
      final armer = _RecordingUploadArmer();
      final session = ReverseImageSearchSession.single(
        platform: platform,
        uploadArmer: armer,
        provider: OutcomeReverseImageProvider(
          const ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.challenge,
            message: 'challenge',
          ),
        ),
      );
      final controller = _flowController(session);
      await controller.prepare(_picked);
      await controller.search();
      expect(
        controller.state.failure?.code,
        ReverseImageProviderFailureCode.challenge,
      );

      await controller.searchInBrowser();
      final state = controller.state;
      expect(state.status, ReverseImageFlowStatus.success);
      expect(state.webUpload?.engine, ReverseImageEngine.sauceNao);
      expect(
        state.webUpload?.uploadPageUrl,
        Uri.parse('https://saucenao.com/'),
      );
      expect(armer.armedPaths, [file.path]);
      expect(state.webUpload?.armedUri, 'content://armed/1');
    },
  );

  test(
    'a large image is scaled to a 2048 long edge JPEG, not refused',
    () async {
      final source = img.Image(width: 3000, height: 1500);
      img.fill(source, color: img.ColorRgb8(200, 80, 120));
      final file = File('${tempDirectory.path}/large.png')
        ..writeAsBytesSync(img.encodePng(source));
      final platform = _FakeReverseImageInputPlatform(file);
      final session = ReverseImageSearchSession.single(
        platform: platform,
        provider: OutcomeReverseImageProvider(
          const ReverseImageSearchSuccess(),
        ),
      );
      final controller = _flowController(session);
      await controller.prepare(
        ReverseImageInputReference(
          contentUri: 'content://share/1',
          mimeType: 'image/png',
          sizeBytes: file.lengthSync(),
          hasReadUriPermission: true,
          source: ReverseImageInputSource.picker,
        ),
      );

      final state = controller.state;
      expect(state.status, ReverseImageFlowStatus.ready);
      final input = state.input!;
      expect((input.width, input.height), (2048, 1024));
      expect(input.format, ReverseImageFormat.jpeg);
      expect(input.path, '${file.path}.scaled.jpg');
      // The picked copy is released as soon as the scaled one exists.
      expect(platform.deletedPaths, [file.path]);
    },
  );

  test('selectEngine without a held image only moves the selection', () async {
    final file = File('${tempDirectory.path}/image.png')
      ..writeAsBytesSync(pngHeader(12, 8));
    final platform = _FakeReverseImageInputPlatform(file);
    final session = ReverseImageSearchSession(
      platform: platform,
      providers: const {},
    );
    final controller = _flowController(session);

    await controller.selectEngine(ReverseImageEngine.iqdb);
    final state = controller.state;
    expect(state.engine, ReverseImageEngine.iqdb);
    expect(state.status, ReverseImageFlowStatus.idle);
  });

  test(
    'a missing engine in the map is an explicit unavailable failure',
    () async {
      final file = File('${tempDirectory.path}/image.png')
        ..writeAsBytesSync(pngHeader(12, 8));
      final platform = _FakeReverseImageInputPlatform(file);
      final session = ReverseImageSearchSession(
        platform: platform,
        providers: {
          ReverseImageEngine.sauceNao: OutcomeReverseImageProvider(
            const ReverseImageSearchSuccess(),
          ),
        },
      );
      final controller = _flowController(session);
      await controller.prepare(_picked);

      await controller.selectEngine(ReverseImageEngine.ascii2d);
      await controller.search();

      final state = controller.state;
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
      ..writeAsBytesSync(pngHeader(12, 8));
    final platform = _FakeReverseImageInputPlatform(file);
    final armer = _RecordingUploadArmer();
    final session = ReverseImageSearchSession.single(
      platform: platform,
      provider: OutcomeReverseImageProvider(
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
    final controller = _flowController(session);
    await controller.prepare(_picked);
    await controller.search();

    final state = controller.state;
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
        ..writeAsBytesSync(pngHeader(12, 8));
      final platform = _FakeReverseImageInputPlatform(file);
      final armer = _RecordingUploadArmer(failArm: true);
      final session = ReverseImageSearchSession.single(
        platform: platform,
        provider: OutcomeReverseImageProvider(
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
      final controller = _flowController(session);
      await controller.prepare(_picked);
      await controller.search();

      final state = controller.state;
      expect(state.status, ReverseImageFlowStatus.failure);
      expect(state.engine, ReverseImageEngine.tinEye);
      expect(state.engineFailures, contains(ReverseImageEngine.tinEye));
      expect(platform.deletedPaths, isEmpty);
    },
  );

  group('stopSearch', () {
    test(
      'stopping a running search returns to ready and keeps the image',
      () async {
        final file = File('${tempDirectory.path}/image.png')
          ..writeAsBytesSync(pngHeader(12, 8));
        final platform = _FakeReverseImageInputPlatform(file);
        final provider = OutcomeReverseImageProvider(
          const ReverseImageSearchSuccess(),
        )..blocker = Completer<ReverseImageSearchOutcome>();
        final session = ReverseImageSearchSession.single(
          platform: platform,
          provider: provider,
        );
        final controller = _flowController(session);

        await controller.prepare(_picked);
        unawaited(controller.search());
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.status, ReverseImageFlowStatus.searching);

        await controller.stopSearch();
        var state = controller.state;
        expect(state.status, ReverseImageFlowStatus.ready);
        expect(state.input, isNotNull);
        // The image must survive the stop so the user can retry.
        expect(platform.deletedPaths, isEmpty);

        // A late provider result belongs to a dead generation and is dropped.
        provider.blocker!.complete(const ReverseImageSearchSuccess());
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        state = controller.state;
        expect(state.status, ReverseImageFlowStatus.ready);
        expect(state.input, isNotNull);
        expect(platform.deletedPaths, isEmpty);
      },
    );

    test(
      'stopping during prepare returns to idle and drops the late copy',
      () async {
        final file = File('${tempDirectory.path}/image.png')
          ..writeAsBytesSync(pngHeader(12, 8));
        final platform = _FakeReverseImageInputPlatform(file)
          ..copyBlocker = Completer<String>();
        final session = ReverseImageSearchSession.single(
          platform: platform,
          provider: OutcomeReverseImageProvider(
            const ReverseImageSearchSuccess(),
          ),
        );
        final controller = _flowController(session);

        unawaited(controller.prepare(_picked));
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.status, ReverseImageFlowStatus.preparing);

        await controller.stopSearch();
        expect(controller.state.status, ReverseImageFlowStatus.idle);

        // The late copy result is discarded — and its file cleaned up —
        // instead of reviving the flow.
        platform.copyBlocker!.complete(file.path);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.status, ReverseImageFlowStatus.idle);
        expect(platform.deletedPaths, [file.path]);
      },
    );

    test('stopping during pick discards the late picker result', () async {
      final file = File('${tempDirectory.path}/image.png')
        ..writeAsBytesSync(pngHeader(12, 8));
      final platform = _FakeReverseImageInputPlatform(file)
        ..pickBlocker = Completer<ReverseImageInputReference?>();
      final session = ReverseImageSearchSession.single(
        platform: platform,
        provider: OutcomeReverseImageProvider(
          const ReverseImageSearchSuccess(),
        ),
      );
      final controller = _flowController(session);

      unawaited(controller.pick());
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.status, ReverseImageFlowStatus.picking);

      await controller.stopSearch();
      expect(controller.state.status, ReverseImageFlowStatus.idle);

      // The picker answering after the stop must not start a prepare —
      // the stale generation throws the reference away.
      platform.pickBlocker!.complete(_picked);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.status, ReverseImageFlowStatus.idle);
      expect(platform.copyCount, 0);
    });
  });

  test(
    'DesktopReverseImageInputPlatform supplies Apple UTIs for iOS picker',
    () async {
      List<XTypeGroup>? captured;
      final platform = DesktopReverseImageInputPlatform(
        openFileHandler: ({acceptedTypeGroups = const []}) async {
          captured = acceptedTypeGroups;
          return null;
        },
      );
      expect(await platform.pickImage(), isNull);
      expect(captured, hasLength(1));
      expect(
        captured!.single.uniformTypeIdentifiers,
        containsAll(['public.jpeg', 'public.png', 'org.webmproject.webp']),
      );
    },
  );

  test(
    'parseReverseImageHtmlMatches extracts validated SauceNAO and IQDB matches without relaxing HTTPS-only rules',
    () {
      const sauceNaoHtml =
          '<div class="result"><table><tr><td class="resulttablecontent">'
          '<div class="resultsimilarityinfo">94.82%</div>'
          '<div class="resulttitle"><strong>Starlight &amp; Dusk</strong></div>'
          '<a href="https://www.pixiv.net/users/77">Author</a>'
          '<a href="https://www.pixiv.net/member_illust.php?mode=medium&amp;illust_id=123456">123456</a>'
          '<a href="https://saucenao.com/search.php?db=999">self</a>'
          '</td></tr></table></div>'
          '<div class="result"><table><tr><td class="resulttablecontent">'
          '<div class="resultsimilarityinfo">88.10%</div>'
          '<div class="resulttitle"><strong>Danbooru Mirror</strong></div>'
          '<a href="https://danbooru.donmai.us/posts/9988">post</a>'
          '<a href="http://insecure.example.com/bad">http</a>'
          '<a href="file:///tmp/result.html">file</a>'
          '</td></tr></table></div>';
      final sauceMatches = parseReverseImageHtmlMatches(
        ReverseImageEngineSpecs.sauceNao,
        sauceNaoHtml,
      );
      expect(sauceMatches, hasLength(2));
      expect(sauceMatches[0].action, ReverseImageNavigationAction.openIllust);
      expect(sauceMatches[0].illustId, 123456);
      expect(sauceMatches[0].title, 'Starlight & Dusk');
      expect(sauceMatches[0].similarity, '94.82%');
      expect(sauceMatches[1].action, ReverseImageNavigationAction.openExternal);
      expect(
        sauceMatches[1].uri,
        Uri.parse('https://danbooru.donmai.us/posts/9988'),
      );

      const iqdbHtml =
          '<div id="pages">'
          '<div><table><tr><th>Your image</th></tr><tr><td><a href="https://iqdb.org/">self</a></td></tr></table></div>'
          '<div><table><tr><th>Best match</th></tr>'
          '<tr><td><a href="//danbooru.donmai.us/posts/4242">Danbooru</a></td></tr>'
          '<tr><td>91% similarity</td></tr></table></div>'
          '<div><table><tr><th>No relevant matches</th></tr></table></div></div>';
      final iqdbMatches = parseReverseImageHtmlMatches(
        ReverseImageEngineSpecs.iqdb,
        iqdbHtml,
      );
      expect(iqdbMatches, hasLength(1));
      expect(
        iqdbMatches.single.action,
        ReverseImageNavigationAction.openExternal,
      );
      expect(
        iqdbMatches.single.uri,
        Uri.parse('https://danbooru.donmai.us/posts/4242'),
      );
      expect(iqdbMatches.single.similarity, '91%');

      for (final raw in const [
        'file:///tmp/result.html',
        'http://example.com/a',
      ]) {
        expect(
          () => validateExternalResultUrl(Uri.parse(raw)),
          throwsFormatException,
        );
      }
    },
  );

  group('SharedImageValidator', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('shared_image_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    File write(String name, {int size = 10}) {
      final file = File('${tempDir.path}/$name');
      file.writeAsBytesSync(Uint8List(size));
      return file;
    }

    test('accepts a readable image within the size limit', () {
      final file = write('cat.png', size: 128);
      final image = SharedImageValidator.validate(
        path: file.path,
        mimeType: 'image/png',
      );
      expect(image.sizeBytes, 128);
      expect(image.path, file.path);
    });

    test('rejects non-images, missing, empty and oversized files', () {
      for (final (path, mimeType) in [
        (write('note.txt').path, 'text/plain'),
        (write('note.zip').path, 'application/zip'),
        ('${tempDir.path}/missing.png', 'image/png'),
        (write('empty.png', size: 0).path, 'image/jpeg'),
        (
          write('huge.png', size: SharedImageValidator.maxBytes + 1).path,
          'image/png',
        ),
      ]) {
        expect(
          () => SharedImageValidator.validate(path: path, mimeType: mimeType),
          throwsA(isA<SharedImageRejected>()),
          reason: path,
        );
      }
    });

    test('accepts an image exactly at the size limit', () {
      final file = write('edge.png', size: SharedImageValidator.maxBytes);
      expect(
        SharedImageValidator.validate(
          path: file.path,
          mimeType: 'image/webp',
        ).sizeBytes,
        SharedImageValidator.maxBytes,
      );
    });
  });

  group('ReverseImageNavigationPolicy', () {
    final policy = ReverseImageNavigationPolicy(
      ReverseImageEngineSpecs.sauceNao.webViewHosts,
    );

    ReverseImageNavigationAction decide(String url) =>
        policy.decide(Uri.tryParse(url));

    test('each link gets its action', () {
      const navigate = ReverseImageNavigationAction.navigate;
      const openIllust = ReverseImageNavigationAction.openIllust;
      const openUser = ReverseImageNavigationAction.openUser;
      const openExternal = ReverseImageNavigationAction.openExternal;
      const reject = ReverseImageNavigationAction.reject;
      for (final (url, action) in [
        ('https://saucenao.com/search.php?db=999', navigate),
        ('https://www.saucenao.com/results?x=1', navigate),
        ('https://saucenao.com/tools.php', navigate),
        ('https://www.pixiv.net/artworks/12345', openIllust),
        ('https://www.pixiv.net/i/99', openIllust),
        ('https://www.pixiv.net/en/artworks/1', openIllust),
        (
          'https://www.pixiv.net/member_illust.php?mode=medium&illust_id=99',
          openIllust,
        ),
        ('https://www.pixiv.net/users/42', openUser),
        ('https://www.pixiv.net/u/7', openUser),
        ('https://www.pixiv.net/member.php?id=42', openUser),
        ('https://example.com/result', openExternal),
        ('https://www.pixiv.net/help', openExternal),
        ('http://saucenao.com/x', reject),
        ('javascript:alert(1)', reject),
        ('https://', reject),
        ('', reject),
        ('https://user:pass@example.com/x', reject),
        ('https://example.com/x#frag', reject),
      ]) {
        expect(decide(url), action, reason: url);
      }
      expect(policy.decide(null), reject);
    });

    test('each engine host set scopes its own webview', () {
      for (final spec in ReverseImageEngineSpecs.all.values) {
        final enginePolicy = ReverseImageNavigationPolicy(spec.webViewHosts);
        for (final host in spec.webViewHosts) {
          expect(
            enginePolicy.decide(Uri.parse('https://$host/')),
            ReverseImageNavigationAction.navigate,
            reason: '${spec.engine} should navigate inside $host',
          );
        }
        final foreign = ReverseImageEngineSpecs.all.values
            .expand((other) => other.webViewHosts)
            .firstWhere((host) => !spec.webViewHosts.contains(host));
        expect(
          enginePolicy.decide(Uri.parse('https://$foreign/')),
          isNot(ReverseImageNavigationAction.navigate),
          reason: '${spec.engine} must not navigate to $foreign',
        );
      }
    });
  });
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
  Completer<ReverseImageInputReference?>? pickBlocker;
  Completer<String>? copyBlocker;
  ReverseImageInputReference? pickResult;

  @override
  Future<String> copyToOwnedFile(ReverseImageInputReference reference) async {
    copyCount++;
    final blocker = copyBlocker;
    if (blocker != null) return blocker.future;
    return file.path;
  }

  @override
  Future<void> deleteOwnedFile(String path) async => deletedPaths.add(path);

  @override
  Future<ReverseImageInputReference?> pickImage() async {
    final blocker = pickBlocker;
    if (blocker != null) return blocker.future;
    return pickResult;
  }
}

/// A VP8X WebP header: RIFF, WEBP, the chunk, then 24-bit sizes minus one.
Uint8List _webpHeader(int width, int height) {
  List<int> le24(int value) => [
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
  ];
  return Uint8List.fromList([
    ...'RIFF'.codeUnits,
    0,
    0,
    0,
    0,
    ...'WEBP'.codeUnits,
    ...'VP8X'.codeUnits,
    10,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    ...le24(width - 1),
    ...le24(height - 1),
  ]);
}
