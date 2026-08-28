import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/updater/update_manifest.dart';
import 'package:pixiv_func/core/updater/update_service.dart';

void main() {
  group('UpdateManifest', () {
    test('rejects unknown schema before release fields are trusted', () {
      final value = _manifestValue()..['schema'] = 99;

      expect(
        () => UpdateManifest.parse(jsonEncode(value)),
        throwsA(isA<UpdateManifestFormatException>()),
      );
    });

    test('rejects an asset URL outside the signed host policy', () {
      final value = _manifestValue()
        ..['asset'] = <String, Object?>{
          ...(_manifestValue()['asset']! as Map<String, Object?>),
          'url': 'https://evil.example/update.apk',
        };

      expect(
        () => UpdateManifest.parse(jsonEncode(value)),
        throwsA(isA<UpdateManifestFormatException>()),
      );
    });

    test('parses a strict stable release and semver prerelease', () {
      final manifest = UpdateManifest.parse(jsonEncode(_manifestValue()));

      expect(manifest.repository, 'Lopution/Pixiv-func');
      expect(manifest.version.toString(), '0.1.1');
      expect(manifest.channel, UpdateChannel.stable);
      expect(manifest.asset.exactSize, 4);
      expect(manifest.asset.sha256, hasLength(64));
    });
  });

  group('UpdateService.check', () {
    test('F-Droid capability never fetches a manifest or signature', () async {
      final transport = _FakeManifestTransport();
      final service = UpdateService(
        platform: _FakePlatform(UpdateCapability.fdroid()),
        manifestTransport: transport,
        signatureVerifier: _FakeSignatureVerifier(valid: true),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.disabled);
      expect(transport.requested, isEmpty);
    });

    test('invalid signature cannot produce UpdateAvailable', () async {
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(_manifestValue())),
        signature: base64Encode(List<int>.filled(64, 1)).codeUnits,
      );
      final service = UpdateService(
        platform: _FakePlatform(UpdateCapability.github()),
        manifestTransport: transport,
        signatureVerifier: _FakeSignatureVerifier(valid: false),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.invalid);
      expect(result.release, isNull);
    });

    test('valid signature is required before a release is available', () async {
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(_manifestValue())),
        signature: base64Encode(List<int>.filled(64, 2)).codeUnits,
      );
      final service = UpdateService(
        platform: _FakePlatform(UpdateCapability.github()),
        manifestTransport: transport,
        signatureVerifier: _FakeSignatureVerifier(valid: true),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.available);
      expect(
        result.release!.manifest.asset.packageName,
        'io.github.lopution.pixivfunc',
      );
    });

    test(
      '429 is surfaced as rate limited without parsing release data',
      () async {
        final transport = _FakeManifestTransport(
          body: utf8.encode(jsonEncode(_manifestValue())),
          manifestStatus: 429,
        );
        final service = UpdateService(
          platform: _FakePlatform(UpdateCapability.github()),
          manifestTransport: transport,
          signatureVerifier: _FakeSignatureVerifier(valid: true),
        );

        final result = await service.check();

        expect(result.status, UpdateCheckStatus.rateLimited);
        expect(result.release, isNull);
        expect(transport.requested, hasLength(1));
      },
    );

    test('signature endpoint 429 is also surfaced as rate limited', () async {
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(_manifestValue())),
        signature: base64Encode(List<int>.filled(64, 7)).codeUnits,
        signatureStatus: 429,
      );
      final service = UpdateService(
        platform: _FakePlatform(UpdateCapability.github()),
        manifestTransport: transport,
        signatureVerifier: _FakeSignatureVerifier(valid: true),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.rateLimited);
      expect(result.errorCode, 'signature_rate_limited');
      expect(transport.requested, hasLength(2));
    });

    test('offline transport is reported as offline', () async {
      final service = UpdateService(
        platform: _FakePlatform(UpdateCapability.github()),
        manifestTransport: _FakeManifestTransport(
          manifestError: const SocketException('offline'),
        ),
        signatureVerifier: _FakeSignatureVerifier(valid: true),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.offline);
      expect(result.errorCode, 'network');
    });

    test('signature transport failure is reported as offline', () async {
      final service = UpdateService(
        platform: _FakePlatform(UpdateCapability.github()),
        manifestTransport: _FakeManifestTransport(
          body: utf8.encode(jsonEncode(_manifestValue())),
          signatureError: const SocketException('offline'),
        ),
        signatureVerifier: _FakeSignatureVerifier(valid: true),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.offline);
      expect(result.errorCode, 'network');
    });

    test('malformed signature is rejected before verification', () async {
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(_manifestValue())),
        signature: utf8.encode('not-base64'),
      );
      final service = UpdateService(
        platform: _FakePlatform(UpdateCapability.github()),
        manifestTransport: transport,
        signatureVerifier: _FakeSignatureVerifier(valid: true),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.invalid);
      expect(result.errorCode, 'signature_format');
    });

    test(
      'stable channel does not expose prerelease as an installable update',
      () async {
        final value = _manifestValue()
          ..['version'] = '0.1.1-beta.1'
          ..['tag'] = 'v0.1.1-beta.1'
          ..['channel'] = 'beta';
        final transport = _FakeManifestTransport(
          body: utf8.encode(jsonEncode(value)),
          signature: base64Encode(List<int>.filled(64, 3)).codeUnits,
        );
        final service = UpdateService(
          platform: _FakePlatform(UpdateCapability.github()),
          manifestTransport: transport,
          signatureVerifier: _FakeSignatureVerifier(valid: true),
        );

        final result = await service.check(channel: UpdateChannel.stable);

        expect(result.status, UpdateCheckStatus.prerelease);
        expect(result.release, isNull);
      },
    );

    test('unknown channel is rejected after signature verification', () async {
      final value = _manifestValue()..['channel'] = 'canary';
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(value)),
        signature: base64Encode(List<int>.filled(64, 4)).codeUnits,
      );
      final service = UpdateService(
        platform: _FakePlatform(UpdateCapability.github()),
        manifestTransport: transport,
        signatureVerifier: _FakeSignatureVerifier(valid: true),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.invalid);
      expect(result.errorCode, 'channel');
      expect(result.release, isNull);
    });

    test(
      'oversize manifest is rejected before signature verification',
      () async {
        final transport = _FakeManifestTransport(
          body: List<int>.filled(updateManifestMaxBytes + 1, 0x78),
          signature: base64Encode(List<int>.filled(64, 5)).codeUnits,
        );
        final verifier = _FakeSignatureVerifier(valid: true);
        final service = UpdateService(
          platform: _FakePlatform(UpdateCapability.github()),
          manifestTransport: transport,
          signatureVerifier: verifier,
        );

        final result = await service.check();

        expect(result.status, UpdateCheckStatus.invalid);
        expect(result.errorCode, 'manifest_http');
        expect(verifier.calls, 0);
      },
    );

    test('asset signer mismatch is not exposed as an available update', () async {
      final value = _manifestValue()
        ..['asset'] = <String, Object?>{
          ...(_manifestValue()['asset']! as Map<String, Object?>),
          'signingCertificateSha256':
              '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
        };
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(value)),
        signature: base64Encode(List<int>.filled(64, 6)).codeUnits,
      );
      final service = UpdateService(
        platform: _FakePlatform(UpdateCapability.github()),
        manifestTransport: transport,
        signatureVerifier: _FakeSignatureVerifier(valid: true),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.invalid);
      expect(result.errorCode, 'asset_identity_mismatch');
      expect(result.release, isNull);
    });
  });
}

Map<String, Object?> _manifestValue() => <String, Object?>{
  'schema': 1,
  'repository': 'Lopution/Pixiv-func',
  'tag': 'v0.1.1',
  'channel': 'stable',
  'version': '0.1.1',
  'versionCode': 2,
  'asset': <String, Object?>{
    'url':
        'https://github.com/Lopution/Pixiv-func/releases/download/v0.1.1/app.apk',
    'size': 4,
    'sha256':
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    'packageName': 'io.github.lopution.pixivfunc',
    'signingCertificateSha256':
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
  },
};

class _FakeManifestTransport implements UpdateManifestTransport {
  _FakeManifestTransport({
    this.body = const [],
    this.signature = const [],
    this.manifestStatus = 200,
    this.signatureStatus = 200,
    this.manifestError,
    this.signatureError,
  });

  final List<int> body;
  final List<int> signature;
  final int manifestStatus;
  final int signatureStatus;
  final Object? manifestError;
  final Object? signatureError;
  final requested = <Uri>[];

  @override
  Future<UpdateHttpResponse> fetch(Uri uri) async {
    requested.add(uri);
    final isManifest = requested.length == 1;
    final error = isManifest ? manifestError : signatureError;
    if (error != null) throw error;
    return UpdateHttpResponse(
      statusCode: isManifest ? manifestStatus : signatureStatus,
      body: isManifest ? body : signature,
    );
  }
}

class _FakeSignatureVerifier implements UpdateSignatureVerifier {
  _FakeSignatureVerifier({required this.valid});

  final bool valid;
  var calls = 0;

  @override
  Future<bool> verify({
    required List<int> message,
    required List<int> signature,
  }) async {
    calls++;
    return valid;
  }
}

class _FakePlatform implements UpdatePlatform {
  _FakePlatform(this._capability);

  final UpdateCapability _capability;

  @override
  Future<UpdateCapability> capability() async => _capability;

  @override
  Future<UpdatePlatformInfo> info() async => const UpdatePlatformInfo(
    packageName: 'io.github.lopution.pixivfunc',
    version: '0.1.0',
    versionCode: 1,
    signingCertificateSha256:
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
  );

  @override
  Future<bool> deleteApk(String path) async => true;

  @override
  Future<bool> verifyManifestSignature({
    required List<int> message,
    required List<int> signature,
  }) async => false;

  @override
  Future<UpdateInstallResult> installApk(String path) async =>
      const UpdateInstallResult.failed('not used by check tests');

  @override
  Future<UpdateApkVerification> verifyApk({
    required String path,
    required UpdateReleaseAsset asset,
  }) async => const UpdateApkVerification.invalid('not used by check tests');
}
