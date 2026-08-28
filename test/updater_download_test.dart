import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/download/download_manager.dart';
import 'package:pixiv_func/core/download/download_request.dart';
import 'package:pixiv_func/core/download/download_transport.dart';
import 'package:pixiv_func/core/download/pixiv_download_transport.dart';
import 'package:pixiv_func/core/updater/update_download.dart';
import 'package:pixiv_func/core/updater/update_manifest.dart';
import 'package:pixiv_func/core/updater/update_service.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pixiv-updater-test-');
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test(
    'streams APK to an owned file and verifies exact size/hash/signer',
    () async {
      final bytes = <int>[1, 2, 3, 4];
      final release = _release(bytes);
      final platform = _FakePlatform();
      final manager = DownloadManager(
        transport: _BytesTransport(bytes),
        sinkFactory: UpdateFileSinkFactory(directory),
      );
      final coordinator = UpdateDownloadCoordinator(
        manager: manager,
        platform: platform,
        directory: directory,
        stateStore: MemoryUpdateDownloadStateStore(),
      );

      final result = await coordinator.download(release);

      expect(result.status, UpdateApplyStatus.downloaded);
      expect(result.path, isNotNull);
      expect(File(result.path!).readAsBytesSync(), bytes);
      expect(platform.verifyCalls, 1);
      await manager.dispose();
    },
  );

  test('hash or exact-size mismatch fails closed and cleans the APK', () async {
    final release = _release(<int>[
      1,
      2,
      3,
      4,
    ], expectedHash: List.filled(64, '0').join());
    final manager = DownloadManager(
      transport: _BytesTransport(<int>[1, 2, 3, 4]),
      sinkFactory: UpdateFileSinkFactory(directory),
    );
    final coordinator = UpdateDownloadCoordinator(
      manager: manager,
      platform: _FakePlatform(),
      directory: directory,
      stateStore: MemoryUpdateDownloadStateStore(),
    );

    final result = await coordinator.download(release);

    expect(result.status, UpdateApplyStatus.failed);
    expect(result.errorCode, 'apk_hash_mismatch');
    expect(directory.listSync(), isEmpty);
    await manager.dispose();
  });

  test(
    'cancel stops the active updater download and removes its APK',
    () async {
      final transport = _BlockingTransport();
      final manager = DownloadManager(
        transport: transport,
        sinkFactory: UpdateFileSinkFactory(directory),
      );
      final coordinator = UpdateDownloadCoordinator(
        manager: manager,
        platform: _FakePlatform(),
        directory: directory,
        stateStore: MemoryUpdateDownloadStateStore(),
      );
      final download = coordinator.download(_release(<int>[1, 2, 3, 4]));

      await transport.opened.future;
      await coordinator.cancel();

      final result = await download;

      expect(result.status, UpdateApplyStatus.canceled);
      expect(directory.listSync(), isEmpty);
      await manager.dispose();
    },
  );

  test(
    'apply requires explicit confirmation and never silently installs',
    () async {
      final release = _release(<int>[1, 2, 3, 4]);
      final platform = _FakePlatform();
      final downloader = _FakeDownloader(
        const UpdateApplyResult(
          status: UpdateApplyStatus.downloaded,
          path: '/owned/update.apk',
        ),
      );
      final service = UpdateService(
        manifestTransport: _UnusedTransport(),
        platform: platform,
        signatureVerifier: _AlwaysValidSignature(),
        downloader: downloader,
      );

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
      final platform = _FakePlatform();
      final downloader = _FakeDownloader(
        const UpdateApplyResult(
          status: UpdateApplyStatus.downloaded,
          path: '/owned/update.apk',
        ),
      );
      final service = UpdateService(
        manifestTransport: _UnusedTransport(),
        platform: platform,
        signatureVerifier: _AlwaysValidSignature(),
        downloader: downloader,
      );

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
    final service = UpdateService(
      manifestTransport: _UnusedTransport(),
      platform: _FakePlatform(),
      signatureVerifier: _AlwaysValidSignature(),
      downloader: downloader,
    );

    await service.cancel();

    expect(downloader.cancelCalls, 1);
  });

  test('installer exception fails and cleans the verified APK', () async {
    final release = _release(<int>[1, 2, 3, 4]);
    final platform = _FakePlatform(
      installError: const UpdatePlatformException('installer_unavailable'),
    );
    final downloader = _FakeDownloader(
      const UpdateApplyResult(
        status: UpdateApplyStatus.downloaded,
        path: '/owned/update.apk',
      ),
    );
    final service = UpdateService(
      manifestTransport: _UnusedTransport(),
      platform: platform,
      signatureVerifier: _AlwaysValidSignature(),
      downloader: downloader,
    );

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
          'https://github.com/Lopution/Pixiv-func/releases/download/v0.1.1/app.apk',
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

  test('strict updater transport rejects a redirect to a non-APK URL', () async {
    final transport = _ScriptedUpdaterTransport([
      _ScriptedHop(
        statusCode: 302,
        location:
            'https://github.com/Lopution/Pixiv-func/releases/latest/notes',
      ),
    ]);
    addTearDown(transport.dispose);

    expect(
      transport.open(
        Uri.parse(
          'https://github.com/Lopution/Pixiv-func/releases/download/v0.1.1/app.apk',
        ),
        headers: const {},
        cancelToken: DownloadCancelToken(),
      ),
      throwsA(isA<DownloadTransportException>()),
    );
  });
}

UpdateRelease _release(List<int> bytes, {String? expectedHash}) {
  final hash = expectedHash ?? sha256.convert(bytes).toString();
  final value = <String, Object?>{
    'schema': 1,
    'repository': updateRepository,
    'tag': 'v0.1.1',
    'channel': 'stable',
    'version': '0.1.1',
    'versionCode': 2,
    'asset': <String, Object?>{
      'url':
          'https://github.com/Lopution/Pixiv-func/releases/download/v0.1.1/app.apk',
      'size': bytes.length,
      'sha256': hash,
      'packageName': updatePackageName,
      'signingCertificateSha256':
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
    },
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

class _FakePlatform implements UpdatePlatform {
  _FakePlatform({this.installError});

  final Object? installError;
  var installCalls = 0;
  var verifyCalls = 0;

  @override
  Future<UpdateCapability> capability() async =>
      const UpdateCapability.github();

  @override
  Future<UpdatePlatformInfo> info() async => const UpdatePlatformInfo(
    packageName: updatePackageName,
    version: '0.1.0',
    versionCode: 1,
    signingCertificateSha256:
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
  );

  @override
  Future<bool> verifyManifestSignature({
    required List<int> message,
    required List<int> signature,
  }) async => true;

  @override
  Future<UpdateApkVerification> verifyApk({
    required String path,
    required UpdateReleaseAsset asset,
  }) async {
    verifyCalls++;
    return const UpdateApkVerification.valid();
  }

  @override
  Future<UpdateInstallResult> installApk(String path) async {
    installCalls++;
    final error = installError;
    if (error != null) throw error;
    return const UpdateInstallResult.started();
  }

  @override
  Future<bool> deleteApk(String path) async => true;
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
  Future<bool> verify({
    required List<int> message,
    required List<int> signature,
  }) async => true;
}

class _UnusedTransport implements UpdateManifestTransport {
  @override
  Future<UpdateHttpResponse> fetch(Uri uri) =>
      throw StateError('check transport should not be used');
}

class _ScriptedUpdaterTransport extends HttpDownloadTransport {
  _ScriptedUpdaterTransport(this.hops)
    : super(allowedHosts: kUpdateDownloadHosts, strictUrlPolicy: true);

  final List<_ScriptedHop> hops;

  @override
  Future<RawHop> openHop(
    Uri url,
    Map<String, String> headers,
    DownloadCancelToken cancelToken,
  ) async => hops.removeAt(0);
}

class _ScriptedHop implements RawHop {
  _ScriptedHop({required this.statusCode, this.location});

  @override
  final int statusCode;

  final String? location;

  @override
  String? get locationHeader => location;

  @override
  int? get contentLength => 0;

  @override
  Stream<List<int>> get body => Stream<List<int>>.value(const []);

  @override
  Future<void> drain() async {}

  @override
  void abort() {}
}
