import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/updater/update_auto_check.dart';
import 'package:pixiv_func/core/updater/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test(
    'first call checks once; a repeat inside the window is skipped',
    () async {
      final transport = _CountingTransport();
      final service = UpdateService(
        platform: _FakePlatform(UpdateCapability.github()),
        manifestTransport: transport,
        signatureVerifier: _FakeSignatureVerifier(),
      );
      var now = DateTime(2026, 9, 19, 12);
      final autoCheck = UpdateAutoCheck(
        preferences: SharedPreferencesAsync(),
        service: () async => service,
        clock: () => now,
      );

      final first = await autoCheck.checkOnce();
      expect(first, isNotNull);
      expect(first!.status, UpdateCheckStatus.noUpdate);
      expect(transport.fetches, 1);

      final second = await autoCheck.checkOnce();
      expect(second, isNull);
      expect(transport.fetches, 1);

      // Past the window the next call checks again.
      now = now.add(const Duration(hours: 25));
      final third = await autoCheck.checkOnce();
      expect(third, isNotNull);
      expect(transport.fetches, 2);
    },
  );

  test('store-managed capability skips the check entirely', () async {
    final transport = _CountingTransport();
    final service = UpdateService(
      platform: _FakePlatform(UpdateCapability.fdroid()),
      manifestTransport: transport,
      signatureVerifier: _FakeSignatureVerifier(),
    );
    final result = await UpdateAutoCheck(
      preferences: SharedPreferencesAsync(),
      service: () async => service,
    ).checkOnce();

    expect(result, isNull);
    expect(transport.fetches, 0);
  });
}

class _CountingTransport implements UpdateManifestTransport {
  int fetches = 0;

  @override
  Future<UpdateHttpResponse> fetch(Uri uri) async {
    fetches += 1;
    return UpdateHttpResponse(statusCode: 404, body: const []);
  }
}

class _FakeSignatureVerifier implements UpdateSignatureVerifier {
  @override
  Future<UpdateManifestVerification> verify({
    required List<int> message,
    required List<int> signature,
  }) async => const UpdateManifestVerification.valid();
}

class _FakePlatform implements UpdatePlatform {
  _FakePlatform(this._capability);

  final UpdateCapability _capability;

  @override
  Future<UpdateCapability> capability() async => _capability;

  @override
  Future<UpdatePlatformInfo> info() async => UpdatePlatformInfo(
    packageName: 'io.github.lopution.pixivfunc',
    version: '0.1.0',
    versionCode: 1,
    signingCertificateSha256:
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
    supportedAbis: const ['arm64-v8a'],
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
      const UpdateInstallResult.failed('not used by auto-check tests');

  @override
  Future<UpdateApkVerification> verifyApk({
    required String path,
    required UpdateReleaseAsset asset,
  }) async =>
      const UpdateApkVerification.invalid('not used by auto-check tests');
}
