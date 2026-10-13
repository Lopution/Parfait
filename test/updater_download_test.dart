import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_request.dart';
import 'package:parfait/core/download/download_transport.dart';
import 'package:parfait/core/download/pixiv_download_transport.dart';
import 'package:parfait/core/updater/update_download.dart';
import 'package:parfait/core/updater/update_manifest.dart';
import 'package:parfait/core/updater/update_service.dart';
import 'helpers/updater_fakes.dart';
import 'helpers/download_world.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pixiv-updater-test-');
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  // A coordinator downloading through [transport] into the test directory.
  UpdateDownloadCoordinator coordinatorOver(
    DownloadTransport transport, [
    FakeUpdatePlatform? platform,
  ]) {
    final manager = DownloadManager(
      transport: transport,
      sinkFactory: UpdateFileSinkFactory(directory),
    );
    addTearDown(manager.dispose);
    return UpdateDownloadCoordinator(
      manager: manager,
      platform: platform ?? FakeUpdatePlatform(),
      directory: directory,
      stateStore: MemoryUpdateDownloadStateStore(),
    );
  }

  test(
    'streams APK to an owned file and verifies exact size/hash/signer',
    () async {
      final bytes = <int>[1, 2, 3, 4];
      final release = _release(bytes);
      final platform = FakeUpdatePlatform();
      final coordinator = coordinatorOver(_BytesTransport(bytes), platform);

      final result = await coordinator.download(release);

      expect(result.status, UpdateApplyStatus.downloaded);
      expect(result.path, isNotNull);
      expect(File(result.path!).readAsBytesSync(), bytes);
      expect(platform.verifyCalls, 1);
    },
  );

  test('hash or exact-size mismatch fails closed and cleans the APK', () async {
    final release = _release(<int>[
      1,
      2,
      3,
      4,
    ], expectedHash: List.filled(64, '0').join());
    final coordinator = coordinatorOver(_BytesTransport(<int>[1, 2, 3, 4]));

    final result = await coordinator.download(release);

    expect(result.status, UpdateApplyStatus.failed);
    expect(result.errorCode, 'apk_hash_mismatch');
    expect(directory.listSync(), isEmpty);
  });

  test(
    'cancel stops the active updater download and removes its APK',
    () async {
      final transport = _BlockingTransport();
      final coordinator = coordinatorOver(transport);
      final download = coordinator.download(_release(<int>[1, 2, 3, 4]));

      await transport.opened.future;
      await coordinator.cancel();

      final result = await download;

      expect(result.status, UpdateApplyStatus.canceled);
      expect(directory.listSync(), isEmpty);
    },
  );

  test(
    'apply requires explicit confirmation and never silently installs',
    () async {
      final release = _release(<int>[1, 2, 3, 4]);
      final platform = FakeUpdatePlatform();
      final downloader = _downloaded();
      final service = _service(downloader, platform);

      final result = await service.apply(release);

      expect(result.status, UpdateApplyStatus.requiresConfirmation);
      expect(platform.installCalls, 0);
      expect(downloader.calls, 0);
    },
  );

  test(
    'confirmed apply reuses a verified recovery before starting a download',
    () async {
      final release = _release(<int>[1, 2, 3, 4]);
      final platform = FakeUpdatePlatform();
      final downloader = _downloaded();
      final service = _service(downloader, platform);

      final result = await service.apply(release, confirmed: true);

      expect(result.status, UpdateApplyStatus.installStarted);
      expect(downloader.recoverCalls, 1);
      expect(downloader.calls, 0);
      expect(platform.installCalls, 1);
    },
  );

  test('cancel delegates to the downloader task boundary', () async {
    final downloader = _FakeDownloader(
      const UpdateApplyResult(status: UpdateApplyStatus.failed),
    );
    final service = _service(downloader);

    await service.cancel();

    expect(downloader.cancelCalls, 1);
  });

  test('installer exception fails and cleans the verified APK', () async {
    final release = _release(<int>[1, 2, 3, 4]);
    final platform = FakeUpdatePlatform(
      installError: const UpdatePlatformException('installer_unavailable'),
    );
    final downloader = _downloaded();
    final service = _service(downloader, platform);

    final result = await service.apply(release, confirmed: true);

    expect(result.status, UpdateApplyStatus.failed);
    expect(result.errorCode, 'installer_unavailable');
    expect(downloader.cleanupCalls, 1);
  });

  test('state parser rejects unknown fields before recovery trusts it', () {
    final value = <String, Object?>{
      'downloadId': 'download_1',
      'version': '0.1.1',
      'versionCode': 2,
      'assetUrl':
          'https://github.com/Lopution/Parfait/releases/download/v0.1.1/app.apk',
      'exactSize': 4,
      'sha256':
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      'packageName': updatePackageName,
      'signingCertificateSha256':
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
      'path': '/owned/update.apk',
      'unexpected': true,
    };

    expect(
      () => UpdateDownloadState.parse(value),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'strict updater transport rejects a redirect to a non-APK URL',
    () async {
      final transport = _ScriptedUpdaterTransport([
        ScriptedHop(
          contentLength: 0,
          statusCode: 302,
          location: 'https://github.com/Lopution/Parfait/releases/latest/notes',
        ),
      ]);
      addTearDown(transport.dispose);

      expect(_openApk(transport), throwsA(isA<DownloadTransportException>()));
    },
  );

  for (final (name, location) in [
    (
      'the GitHub CDN opaque asset path',
      'https://objects.githubusercontent.com/github-production-release-asset-2e65be/opaque-token',
    ),
    // The chain measured on 2026-09-07: github.com 302 -> one hop to
    // release-assets.githubusercontent.com whose path has no .apk suffix.
    (
      'the measured release-assets CDN hop',
      'https://release-assets.githubusercontent.com/github-production-release-asset/1347042509/0f4d2c1e-0000-4000-8000-000000000000',
    ),
    ('a GitHub release redirect hop', _apkUrl),
  ]) {
    test('strict updater transport accepts $name', () async {
      final transport = _ScriptedUpdaterTransport([
        ScriptedHop(contentLength: 0, statusCode: 302, location: location),
        ScriptedHop(contentLength: 0, statusCode: 200),
      ]);
      addTearDown(transport.dispose);

      expect((await _openApk(transport)).statusCode, 200);
    });
  }
}

const _apkUrl =
    'https://github.com/Lopution/Parfait/releases/download/v0.1.1/app.apk';

Future<DownloadResponse> _openApk(DownloadTransport transport) =>
    transport.open(
      Uri.parse(_apkUrl),
      headers: const {},
      cancelToken: DownloadCancelToken(),
    );

UpdateService _service(
  _FakeDownloader downloader, [
  FakeUpdatePlatform? platform,
]) => UpdateService(
  manifestTransport: UnusedManifestTransport(),
  platform: platform ?? FakeUpdatePlatform(),
  signatureVerifier: _AlwaysValidSignature(),
  downloader: downloader,
);

_FakeDownloader _downloaded() => _FakeDownloader(
  const UpdateApplyResult(
    status: UpdateApplyStatus.downloaded,
    path: '/owned/update.apk',
  ),
);

UpdateRelease _release(List<int> bytes, {String? expectedHash}) {
  final hash = expectedHash ?? sha256.convert(bytes).toString();
  final value = <String, Object?>{
    'schema': 2,
    'repository': updateRepository,
    'tag': 'v0.1.1',
    'channel': 'stable',
    'version': '0.1.1',
    'versionCode': 2,
    'packageName': updatePackageName,
    'signingCertificateSha256':
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
    'assets': <Map<String, Object?>>[
      <String, Object?>{
        'abi': 'arm64-v8a',
        'url':
            'https://github.com/Lopution/Parfait/releases/download/v0.1.1/parfait-v0.1.1-github-arm64-v8a.apk',
        'size': bytes.length,
        'sha256': hash,
        'versionCode': 2002,
      },
      <String, Object?>{
        'abi': 'armeabi-v7a',
        'url':
            'https://github.com/Lopution/Parfait/releases/download/v0.1.1/parfait-v0.1.1-github-armeabi-v7a.apk',
        'size': bytes.length,
        'sha256': hash,
        'versionCode': 1002,
      },
    ],
  };
  final raw = jsonEncode(value).codeUnits;
  return UpdateRelease(
    manifest: UpdateManifest.parse(String.fromCharCodes(raw)),
    rawManifest: raw,
  );
}

class _BytesTransport implements DownloadTransport {
  _BytesTransport(this.bytes);

  final List<int> bytes;

  @override
  Future<DownloadResponse> open(
    Uri url, {
    required Map<String, String> headers,
    required DownloadCancelToken cancelToken,
  }) async => _BytesResponse(bytes);
}

class _BlockingTransport implements DownloadTransport {
  final opened = Completer<void>();

  @override
  Future<DownloadResponse> open(
    Uri url, {
    required Map<String, String> headers,
    required DownloadCancelToken cancelToken,
  }) async {
    opened.complete();
    await cancelToken.whenCancel;
    throw const DownloadCancelledException();
  }
}

class _BytesResponse implements DownloadResponse {
  _BytesResponse(this.bytes);

  final List<int> bytes;

  @override
  int get statusCode => 200;

  @override
  int get contentLength => bytes.length;

  @override
  Stream<List<int>> get stream => Stream<List<int>>.value(bytes);

  @override
  Future<void> close() async {}
}

class _FakeDownloader implements UpdateApkDownloader {
  _FakeDownloader(this.result);

  final UpdateApplyResult result;
  var calls = 0;
  var recoverCalls = 0;
  var cancelCalls = 0;
  var cleanupCalls = 0;

  @override
  Future<UpdateApplyResult> download(UpdateRelease release) async {
    calls++;
    return result;
  }

  @override
  Future<bool> cleanup(String path) async {
    cleanupCalls++;
    return true;
  }

  @override
  Future<UpdateApplyResult> recover(UpdateRelease release) async {
    recoverCalls++;
    return result;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }
}

class _AlwaysValidSignature implements UpdateSignatureVerifier {
  @override
  Future<UpdateManifestVerification> verify({
    required List<int> message,
    required List<int> signature,
  }) async => const UpdateManifestVerification.valid();
}

class _ScriptedUpdaterTransport extends HttpDownloadTransport {
  _ScriptedUpdaterTransport(this.hops)
    : super(allowedHosts: kUpdateDownloadHosts, strictUrlPolicy: true);

  final List<ScriptedHop> hops;

  @override
  Future<RawHop> openHop(
    Uri url,
    Map<String, String> headers,
    DownloadCancelToken cancelToken,
  ) async => hops.removeAt(0);
}
