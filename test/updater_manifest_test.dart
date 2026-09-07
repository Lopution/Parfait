import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/updater/update_manifest.dart';
import 'package:pixiv_func/core/updater/update_service.dart';

void main() {
  group('UpdateManifest', () {
    test('rejects unknown schema before release fields are trusted', () {
      final value = _manifestValue()..['schema'] = 99;

      expect(
        () => UpdateManifest.parse(jsonEncode(value)),
        throwsA(
          isA<UpdateManifestFormatException>().having(
            (error) => error.code,
            'code',
            'schema',
          ),
        ),
      );
    });

    test('rejects schema 1 with schema', () {
      expect(
        () => UpdateManifest.parse(jsonEncode(_schema1ManifestValue())),
        throwsA(
          isA<UpdateManifestFormatException>().having(
            (error) => error.code,
            'code',
            'schema',
          ),
        ),
      );
    });

    test('rejects an asset URL outside the signed host policy', () {
      final value = _manifestValue();
      final assets = List<Map<String, Object?>>.from(
        (value['assets']! as List).cast<Map<String, Object?>>(),
      );
      assets[0] = <String, Object?>{
        ...assets[0],
        'url': 'https://evil.example/update.apk',
      };
      value['assets'] = assets;

      expect(
        () => UpdateManifest.parse(jsonEncode(value)),
        throwsA(isA<UpdateManifestFormatException>()),
      );
    });

    test('rejects an extra top-level key with manifest_keys', () {
      final value = _manifestValue()..['notes'] = 'x';

      expect(
        () => UpdateManifest.parse(jsonEncode(value)),
        throwsA(_formatError('manifest_keys')),
      );
    });

    test('rejects an extra asset key with asset_keys', () {
      final value = _manifestValue();
      final assets = _assetsOf(value);
      assets[0] = <String, Object?>{...assets[0], 'mirror': 'x'};
      value['assets'] = assets;

      expect(
        () => UpdateManifest.parse(jsonEncode(value)),
        throwsA(_formatError('asset_keys')),
      );
    });

    test('rejects a duplicate ABI with asset_abi', () {
      final value = _manifestValue();
      final assets = _assetsOf(value);
      assets[1] = <String, Object?>{...assets[1], 'abi': 'arm64-v8a'};
      value['assets'] = assets;

      expect(
        () => UpdateManifest.parse(jsonEncode(value)),
        throwsA(_formatError('asset_abi')),
      );
    });

    test('rejects an empty assets list with assets', () {
      final value = _manifestValue()..['assets'] = <Object?>[];

      expect(
        () => UpdateManifest.parse(jsonEncode(value)),
        throwsA(_formatError('assets')),
      );
    });

    test(
      'rejects an asset larger than updateAssetMaxBytes with asset_size',
      () {
        final value = _manifestValue();
        final assets = _assetsOf(value);
        assets[0] = <String, Object?>{
          ...assets[0],
          'size': updateAssetMaxBytes + 1,
        };
        value['assets'] = assets;

        expect(
          () => UpdateManifest.parse(jsonEncode(value)),
          throwsA(_formatError('asset_size')),
        );
      },
    );

    test('rejects upper-case hex in sha256 and certificate with hex', () {
      final upper =
          'ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
      final certValue = _manifestValue()..['signingCertificateSha256'] = upper;
      expect(
        () => UpdateManifest.parse(jsonEncode(certValue)),
        throwsA(_formatError('hex')),
      );

      final shaValue = _manifestValue();
      final assets = _assetsOf(shaValue);
      assets[0] = <String, Object?>{...assets[0], 'sha256': upper};
      shaValue['assets'] = assets;
      expect(
        () => UpdateManifest.parse(jsonEncode(shaValue)),
        throwsA(_formatError('hex')),
      );
    });

    test('parses a strict stable release and semver prerelease', () {
      final manifest = UpdateManifest.parse(jsonEncode(_manifestValue()));

      expect(manifest.repository, 'Lopution/Pixiv-func');
      expect(manifest.version.toString(), '0.1.1');
      expect(manifest.channel, UpdateChannel.stable);
      expect(manifest.assets, hasLength(2));
      expect(manifest.asset.exactSize, 4);
      expect(manifest.asset.sha256, hasLength(64));
      expect(manifest.asset.packageName, updatePackageName);
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
      'ABI selection picks the first supported ABI present in assets',
      () async {
        final transport = _FakeManifestTransport(
          body: utf8.encode(jsonEncode(_manifestValue())),
          signature: base64Encode(List<int>.filled(64, 8)).codeUnits,
        );
        final service = UpdateService(
          platform: _FakePlatform(
            UpdateCapability.github(),
            supportedAbis: const ['armeabi-v7a', 'arm64-v8a'],
          ),
          manifestTransport: transport,
          signatureVerifier: _FakeSignatureVerifier(valid: true),
        );

        final result = await service.check();

        expect(result.status, UpdateCheckStatus.available);
        expect(
          result.release!.manifest.asset.url.toString(),
          _assetUrl('0.1.1', 'armeabi-v7a'),
        );
      },
    );

    test('unsupported ABI is invalid, never up_to_date', () async {
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(_manifestValue())),
        signature: base64Encode(List<int>.filled(64, 9)).codeUnits,
      );
      final service = UpdateService(
        platform: _FakePlatform(
          UpdateCapability.github(),
          supportedAbis: const ['x86_64'],
        ),
        manifestTransport: transport,
        signatureVerifier: _FakeSignatureVerifier(valid: true),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.invalid);
      expect(result.errorCode, 'abi_unsupported');
      expect(result.release, isNull);
    });

    test('installed 2001 is up to date against manifest base 1', () async {
      final value = _manifestValue(version: '0.1.0', versionCode: 1);
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(value)),
        signature: base64Encode(List<int>.filled(64, 10)).codeUnits,
      );
      final service = UpdateService(
        platform: _FakePlatform(
          UpdateCapability.github(),
          version: '0.1.0',
          versionCode: 2001,
        ),
        manifestTransport: transport,
        signatureVerifier: _FakeSignatureVerifier(valid: true),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.noUpdate);
      expect(result.errorCode, 'up_to_date');
    });

    test('installed 2001 is available against manifest base 2', () async {
      final value = _manifestValue(version: '0.1.0', versionCode: 2);
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(value)),
        signature: base64Encode(List<int>.filled(64, 11)).codeUnits,
      );
      final service = UpdateService(
        platform: _FakePlatform(
          UpdateCapability.github(),
          version: '0.1.0',
          versionCode: 2001,
        ),
        manifestTransport: transport,
        signatureVerifier: _FakeSignatureVerifier(valid: true),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.available);
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

    test(
      'asset signer mismatch is not exposed as an available update',
      () async {
        final value = _manifestValue()
          ..['signingCertificateSha256'] =
              '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
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
      },
    );
  });

  group('MethodChannelUpdatePlatform.info', () {
    const channel = MethodChannel('pixivfunc/updater');

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<void> expectMalformed(Object? supportedAbis) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return <String, Object?>{
              'packageName': updatePackageName,
              'version': '0.1.0',
              'versionCode': 1,
              'signingCertificateSha256':
                  'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
              if (supportedAbis != _missingAbis) 'supportedAbis': supportedAbis,
            };
          });

      await expectLater(
        MethodChannelUpdatePlatform(channel).info(),
        throwsA(
          isA<UpdatePlatformException>().having(
            (error) => error.code,
            'code',
            'platform_info_malformed',
          ),
        ),
      );
    }

    test('missing supportedAbis is platform_info_malformed', () {
      return expectMalformed(_missingAbis);
    });

    test('non-list supportedAbis is platform_info_malformed', () {
      return expectMalformed('arm64-v8a');
    });

    test('non-string supportedAbis entries are platform_info_malformed', () {
      return expectMalformed(<Object?>['arm64-v8a', 64]);
    });
  });
}

const Object _missingAbis = Object();

String _assetUrl(String version, String abi) =>
    'https://github.com/Lopution/Pixiv-func/releases/download/v$version/pixiv-func-v$version-github-$abi.apk';

Map<String, Object?> _asset({
  required String version,
  required String abi,
  required int versionCode,
  int size = 4,
}) {
  return <String, Object?>{
    'abi': abi,
    'url': _assetUrl(version, abi),
    'size': size,
    'sha256':
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    'versionCode': versionCode,
  };
}

TypeMatcher<UpdateManifestFormatException> _formatError(String code) =>
    isA<UpdateManifestFormatException>().having(
      (error) => error.code,
      'code',
      code,
    );

List<Map<String, Object?>> _assetsOf(Map<String, Object?> value) =>
    List<Map<String, Object?>>.from(
      (value['assets']! as List).cast<Map<String, Object?>>(),
    );

Map<String, Object?> _manifestValue({
  String version = '0.1.1',
  int versionCode = 2,
}) => <String, Object?>{
  'schema': 2,
  'repository': 'Lopution/Pixiv-func',
  'tag': 'v$version',
  'channel': 'stable',
  'version': version,
  'versionCode': versionCode,
  'packageName': 'io.github.lopution.pixivfunc',
  'signingCertificateSha256':
      'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
  'assets': <Map<String, Object?>>[
    _asset(version: version, abi: 'arm64-v8a', versionCode: 2000 + versionCode),
    _asset(
      version: version,
      abi: 'armeabi-v7a',
      versionCode: 1000 + versionCode,
    ),
  ],
};

Map<String, Object?> _schema1ManifestValue() => <String, Object?>{
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
  Future<UpdateManifestVerification> verify({
    required List<int> message,
    required List<int> signature,
  }) async {
    calls++;
    return valid
        ? const UpdateManifestVerification.valid()
        : const UpdateManifestVerification.invalid('signature_mismatch');
  }
}

class _FakePlatform implements UpdatePlatform {
  _FakePlatform(
    this._capability, {
    this.supportedAbis = const ['arm64-v8a', 'armeabi-v7a'],
    this.version = '0.1.0',
    this.versionCode = 1,
  });

  final UpdateCapability _capability;
  final List<String> supportedAbis;
  final String version;
  final int versionCode;

  @override
  Future<UpdateCapability> capability() async => _capability;

  @override
  Future<UpdatePlatformInfo> info() async => UpdatePlatformInfo(
    packageName: 'io.github.lopution.pixivfunc',
    version: version,
    versionCode: versionCode,
    signingCertificateSha256:
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
    supportedAbis: supportedAbis,
  );

  @override
  Future<bool> deleteApk(String path) async => true;

  @override
  Future<UpdateManifestVerification> verifyManifestSignature({
    required List<int> message,
    required List<int> signature,
  }) async => const UpdateManifestVerification.invalid('signature_mismatch');

  @override
  Future<UpdateInstallResult> installApk(String path) async =>
      const UpdateInstallResult.failed('not used by check tests');

  @override
  Future<UpdateApkVerification> verifyApk({
    required String path,
    required UpdateReleaseAsset asset,
  }) async => const UpdateApkVerification.invalid('not used by check tests');
}
