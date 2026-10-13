import 'package:parfait/core/updater/update_manifest.dart';
import 'package:parfait/core/updater/update_service.dart';

/// An [UpdatePlatform] whose capability and device info each test picks.
/// Manifest signatures verify unless a test passes its own verifier; APK
/// checks pass and installs start (or throw [installError]), counted.
class FakeUpdatePlatform implements UpdatePlatform {
  FakeUpdatePlatform({
    UpdateCapability capability = const UpdateCapability.github(),
    this.supportedAbis = const ['arm64-v8a', 'armeabi-v7a'],
    this.version = '0.1.0',
    this.versionCode = 1,
    this.installError,
  }) : updateCapability = capability;

  final UpdateCapability updateCapability;
  final List<String> supportedAbis;
  final String version;
  final int versionCode;
  final Object? installError;
  var installCalls = 0;
  var verifyCalls = 0;

  @override
  Future<UpdateCapability> capability() async => updateCapability;

  @override
  Future<UpdatePlatformInfo> info() async => UpdatePlatformInfo(
    packageName: updatePackageName,
    version: version,
    versionCode: versionCode,
    signingCertificateSha256:
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
    supportedAbis: supportedAbis,
  );

  @override
  Future<UpdateManifestVerification> verifyManifestSignature({
    required List<int> message,
    required List<int> signature,
  }) async => const UpdateManifestVerification.valid();

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

/// Answers every manifest signature check with [valid], counting calls.
class FakeUpdateSignatureVerifier implements UpdateSignatureVerifier {
  FakeUpdateSignatureVerifier({this.valid = true});

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

/// A manifest transport for flows that must not fetch a manifest.
class UnusedManifestTransport implements UpdateManifestTransport {
  @override
  Future<UpdateHttpResponse> fetch(Uri uri) =>
      throw StateError('the manifest transport is not used here');
}
