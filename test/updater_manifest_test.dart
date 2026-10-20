import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/updater/update_manifest.dart';
import 'package:parfait/core/updater/update_service.dart';
import 'helpers/updater_fakes.dart';

/// Checks for an update over [transport] on [platform] (GitHub builds by
/// default), with a signature that verifies unless [signed] is false.
Future<UpdateCheckResult> _check(
  UpdateManifestTransport transport, {
  FakeUpdatePlatform? platform,
  bool signed = true,
}) => UpdateService(
  platform: platform ?? FakeUpdatePlatform(),
  manifestTransport: transport,
  signatureVerifier: FakeUpdateSignatureVerifier(valid: signed),
).check();

void main() {
  group('UpdateManifest', () {
    test('rejects schema 1 and each malformed field with its code', () {
      Map<String, Object?> withAsset(int index, Map<String, Object?> patch) {
        final value = _manifestValue();
        final assets = _assetsOf(value);
        assets[index] = {...assets[index], ...patch};
        return value..['assets'] = assets;
      }

      const upper =
          'ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
      for (final (value, code) in [
        // An unknown schema is refused before release fields are trusted.
        (_manifestValue()..['schema'] = 99, 'schema'),
        (_schema1ManifestValue(), 'schema'),
        // An asset URL outside the signed host policy.
        (withAsset(0, {'url': 'https://evil.example/update.apk'}), null),
        (_manifestValue()..['notes'] = 'x', 'manifest_keys'),
        (withAsset(0, {'mirror': 'x'}), 'asset_keys'),
        (withAsset(1, {'abi': 'arm64-v8a'}), 'asset_abi'),
        (_manifestValue()..['assets'] = <Object?>[], 'assets'),
        (withAsset(0, {'size': updateAssetMaxBytes + 1}), 'asset_size'),
        (_manifestValue()..['signingCertificateSha256'] = upper, 'hex'),
        (withAsset(0, {'sha256': upper}), 'hex'),
      ]) {
        expect(
          () => UpdateManifest.parse(jsonEncode(value)),
          throwsA(
            code == null
                ? isA<UpdateManifestFormatException>()
                : _formatError(code),
          ),
          reason: '$code',
        );
      }
    });

    test('parses a strict stable release and semver prerelease', () {
      final manifest = UpdateManifest.parse(jsonEncode(_manifestValue()));

      expect(manifest.repository, 'Lopution/Parfait');
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
      final result = await _check(
        transport,
        platform: FakeUpdatePlatform(capability: UpdateCapability.fdroid()),
      );

      expect(result.status, UpdateCheckStatus.disabled);
      expect(transport.requested, isEmpty);
    });

    test('invalid signature cannot produce UpdateAvailable', () async {
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(_manifestValue())),
        signature: base64Encode(List<int>.filled(64, 1)).codeUnits,
      );
      final result = await _check(transport, signed: false);

      expect(result.status, UpdateCheckStatus.invalid);
      expect(result.release, isNull);
    });

    test('valid signature is required before a release is available', () async {
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(_manifestValue())),
        signature: base64Encode(List<int>.filled(64, 2)).codeUnits,
      );
      final service = UpdateService(
        platform: FakeUpdatePlatform(capability: UpdateCapability.github()),
        manifestTransport: transport,
        signatureVerifier: FakeUpdateSignatureVerifier(valid: true),
      );

      final result = await service.check();

      expect(result.status, UpdateCheckStatus.available);
      // The service remembers the outcome — About renders lastCheck
      // without a fresh check.
      expect(service.lastCheck, same(result));
      expect(
        result.release!.manifest.asset.packageName,
        'io.github.lopution.parfait',
      );
    });

    test(
      'ABI selection picks the first supported ABI present in assets',
      () async {
        final transport = _FakeManifestTransport(
          body: utf8.encode(jsonEncode(_manifestValue())),
          signature: base64Encode(List<int>.filled(64, 8)).codeUnits,
        );
        final result = await _check(
          transport,
          platform: FakeUpdatePlatform(
            capability: UpdateCapability.github(),
            supportedAbis: const ['armeabi-v7a', 'arm64-v8a'],
          ),
        );

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
      final result = await _check(
        transport,
        platform: FakeUpdatePlatform(
          capability: UpdateCapability.github(),
          supportedAbis: const ['x86_64'],
        ),
      );

      expect(result.status, UpdateCheckStatus.invalid);
      expect(result.errorCode, 'abi_unsupported');
      expect(result.release, isNull);
    });

    test('installed 2001 is up to date against manifest base 1', () async {
      // Base 2 is newer than 2001's base 1 and is offered.
      for (final (base, status) in [
        (1, UpdateCheckStatus.noUpdate),
        (2, UpdateCheckStatus.available),
      ]) {
        final value = _manifestValue(version: '0.1.0', versionCode: base);
        final result = await _check(
          _FakeManifestTransport(
            body: utf8.encode(jsonEncode(value)),
            signature: base64Encode(List<int>.filled(64, 9 + base)).codeUnits,
          ),
          platform: FakeUpdatePlatform(
            capability: UpdateCapability.github(),
            version: '0.1.0',
            versionCode: 2001,
          ),
        );
        expect(result.status, status, reason: 'base $base');
        if (base == 1) expect(result.errorCode, 'up_to_date');
      }
    });

    test(
      '429 is surfaced as rate limited without parsing release data',
      () async {
        final transport = _FakeManifestTransport(
          body: utf8.encode(jsonEncode(_manifestValue())),
          manifestStatus: 429,
        );
        final result = await _check(transport);

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
      final result = await _check(transport);

      expect(result.status, UpdateCheckStatus.rateLimited);
      expect(result.errorCode, 'signature_rate_limited');
      expect(transport.requested, hasLength(2));
    });

    test('offline transport is reported as offline', () async {
      final result = await _check(
        _FakeManifestTransport(manifestError: const SocketException('offline')),
      );

      expect(result.status, UpdateCheckStatus.offline);
      expect(result.errorCode, 'network');
    });

    test('signature transport failure is reported as offline', () async {
      final result = await _check(
        _FakeManifestTransport(
          body: utf8.encode(jsonEncode(_manifestValue())),
          signatureError: const SocketException('offline'),
        ),
      );

      expect(result.status, UpdateCheckStatus.offline);
      expect(result.errorCode, 'network');
    });

    test('malformed signature is rejected before verification', () async {
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(_manifestValue())),
        signature: utf8.encode('not-base64'),
      );
      final result = await _check(transport);

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
          platform: FakeUpdatePlatform(capability: UpdateCapability.github()),
          manifestTransport: transport,
          signatureVerifier: FakeUpdateSignatureVerifier(valid: true),
        );

        final result = await service.check(channel: UpdateChannel.stable);

        expect(result.status, UpdateCheckStatus.prerelease);
        expect(result.release, isNull);
      },
    );

    test(
      'manifest 404 means no published release yet, not a failure',
      () async {
        final transport = _FakeManifestTransport(manifestStatus: 404);
        final result = await _check(transport);

        expect(result.status, UpdateCheckStatus.noUpdate);
        expect(result.errorCode, 'manifest_not_published');
        // The signature asset is not fetched when the manifest itself is
        // absent.
        expect(transport.requested, hasLength(1));
      },
    );

    test('unknown channel is rejected after signature verification', () async {
      final value = _manifestValue()..['channel'] = 'canary';
      final transport = _FakeManifestTransport(
        body: utf8.encode(jsonEncode(value)),
        signature: base64Encode(List<int>.filled(64, 4)).codeUnits,
      );
      final result = await _check(transport);

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
        final verifier = FakeUpdateSignatureVerifier(valid: true);
        final service = UpdateService(
          platform: FakeUpdatePlatform(capability: UpdateCapability.github()),
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
        final result = await _check(transport);

        expect(result.status, UpdateCheckStatus.invalid);
        expect(result.errorCode, 'asset_identity_mismatch');
        expect(result.release, isNull);
      },
    );
  });

  group('MethodChannelUpdatePlatform.info', () {
    const channel = MethodChannel('parfait/updater');

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
    'https://github.com/Lopution/Parfait/releases/download/v$version/parfait-v$version-github-$abi.apk';

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
  'repository': 'Lopution/Parfait',
  'tag': 'v$version',
  'channel': 'stable',
  'version': version,
  'versionCode': versionCode,
  'packageName': 'io.github.lopution.parfait',
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
  'repository': 'Lopution/Parfait',
  'tag': 'v0.1.1',
  'channel': 'stable',
  'version': '0.1.1',
  'versionCode': 2,
  'asset': <String, Object?>{
    'url':
        'https://github.com/Lopution/Parfait/releases/download/v0.1.1/app.apk',
    'size': 4,
    'sha256':
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    'packageName': 'io.github.lopution.parfait',
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
