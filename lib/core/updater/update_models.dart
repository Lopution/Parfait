import 'package:meta/meta.dart';

enum UpdateFlavor { github, fdroid }

enum UpdateChannel { stable, beta }

enum UpdateCheckStatus {
  disabled,
  available,
  noUpdate,
  prerelease,
  invalid,
  rateLimited,
  offline,
  failed,
  busy,
}

enum UpdateApplyStatus {
  disabled,
  requiresConfirmation,
  downloading,
  downloaded,
  installPermissionRequired,
  installStarted,
  canceled,
  failed,
  busy,
}

@immutable
class UpdateCapability {
  const UpdateCapability({
    required this.flavor,
    required this.enabled,
    required this.storeManaged,
  });

  const UpdateCapability.github()
    : flavor = UpdateFlavor.github,
      enabled = true,
      storeManaged = false;

  const UpdateCapability.fdroid()
    : flavor = UpdateFlavor.fdroid,
      enabled = false,
      storeManaged = true;

  final UpdateFlavor flavor;
  final bool enabled;
  final bool storeManaged;
}

@immutable
class UpdatePlatformInfo {
  const UpdatePlatformInfo({
    required this.packageName,
    required this.version,
    required this.versionCode,
    required this.signingCertificateSha256,
  });

  final String packageName;
  final String version;
  final int versionCode;
  final String signingCertificateSha256;
}

@immutable
class UpdateReleaseAsset {
  const UpdateReleaseAsset({
    required this.url,
    required this.exactSize,
    required this.sha256,
    required this.packageName,
    required this.signingCertificateSha256,
  });

  final Uri url;
  final int exactSize;
  final String sha256;
  final String packageName;
  final String signingCertificateSha256;
}

@immutable
class UpdateRelease {
  const UpdateRelease({required this.manifest, required this.rawManifest});

  final UpdateManifestLike manifest;
  final List<int> rawManifest;
}

/// The service only needs this small view of a parsed manifest. The concrete
/// implementation lives in update_manifest.dart to keep parsing separate from
/// service orchestration.
abstract interface class UpdateManifestLike {
  String get repository;
  String get tag;
  UpdateChannel get channel;
  UpdateVersionLike get version;
  int get versionCode;
  UpdateReleaseAsset get asset;
}

abstract interface class UpdateVersionLike
    implements Comparable<UpdateVersionLike> {
  bool get isPrerelease;
}

@immutable
class UpdateCheckResult {
  const UpdateCheckResult({required this.status, this.release, this.errorCode});

  const UpdateCheckResult.disabled() : this(status: UpdateCheckStatus.disabled);

  final UpdateCheckStatus status;
  final UpdateRelease? release;
  final String? errorCode;
}

@immutable
class UpdateInstallResult {
  const UpdateInstallResult._(this.status, [this.errorCode]);

  const UpdateInstallResult.started()
    : this._(UpdateApplyStatus.installStarted);

  const UpdateInstallResult.permissionRequired()
    : this._(UpdateApplyStatus.installPermissionRequired);

  const UpdateInstallResult.canceled() : this._(UpdateApplyStatus.canceled);

  const UpdateInstallResult.failed(String code)
    : this._(UpdateApplyStatus.failed, code);

  final UpdateApplyStatus status;
  final String? errorCode;
}

@immutable
class UpdateApplyResult {
  const UpdateApplyResult({required this.status, this.path, this.errorCode});

  final UpdateApplyStatus status;
  final String? path;
  final String? errorCode;
}

@immutable
class UpdateApkVerification {
  const UpdateApkVerification._(this.valid, this.errorCode);

  const UpdateApkVerification.valid() : this._(true, null);

  const UpdateApkVerification.invalid(String code) : this._(false, code);

  final bool valid;
  final String? errorCode;
}
