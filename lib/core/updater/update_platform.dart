import 'package:flutter/services.dart';

import 'update_models.dart';

abstract interface class UpdatePlatform {
  Future<UpdateCapability> capability();

  Future<UpdatePlatformInfo> info();

  Future<bool> verifyManifestSignature({
    required List<int> message,
    required List<int> signature,
  });

  Future<UpdateApkVerification> verifyApk({
    required String path,
    required UpdateReleaseAsset asset,
  });

  Future<UpdateInstallResult> installApk(String path);

  Future<bool> deleteApk(String path);
}

class MethodChannelUpdatePlatform implements UpdatePlatform {
  MethodChannelUpdatePlatform([
    MethodChannel channel = const MethodChannel('pixivfunc/updater'),
  ]) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<UpdateCapability> capability() async {
    final raw = await _invokeMap('getCapability');
    final flavor = raw['flavor'];
    final enabled = raw['enabled'];
    final storeManaged = raw['storeManaged'];
    if (flavor is! String || enabled is! bool || storeManaged is! bool) {
      throw const UpdatePlatformException('capability_malformed');
    }
    return UpdateCapability(
      flavor: switch (flavor) {
        'github' => UpdateFlavor.github,
        'fdroid' => UpdateFlavor.fdroid,
        _ => throw const UpdatePlatformException('flavor_unknown'),
      },
      enabled: enabled,
      storeManaged: storeManaged,
    );
  }

  @override
  Future<UpdatePlatformInfo> info() async {
    final raw = await _invokeMap('getPlatformInfo');
    final packageName = raw['packageName'];
    final version = raw['version'];
    final versionCode = raw['versionCode'];
    final certificate = raw['signingCertificateSha256'];
    if (packageName is! String ||
        version is! String ||
        versionCode is! int ||
        certificate is! String) {
      throw const UpdatePlatformException('platform_info_malformed');
    }
    return UpdatePlatformInfo(
      packageName: packageName,
      version: version,
      versionCode: versionCode,
      signingCertificateSha256: certificate,
    );
  }

  @override
  Future<bool> verifyManifestSignature({
    required List<int> message,
    required List<int> signature,
  }) async {
    final value = await _channel
        .invokeMethod<Object?>('verifyManifestSignature', <String, Object?>{
          'message': Uint8List.fromList(message),
          'signature': Uint8List.fromList(signature),
        });
    if (value is! bool) {
      throw const UpdatePlatformException('signature_result_malformed');
    }
    return value;
  }

  @override
  Future<UpdateApkVerification> verifyApk({
    required String path,
    required UpdateReleaseAsset asset,
  }) async {
    final value = await _invokeMap('verifyApk', <String, Object?>{
      'path': path,
      'packageName': asset.packageName,
      'signingCertificateSha256': asset.signingCertificateSha256,
    });
    final valid = value['valid'];
    if (valid is! bool) {
      throw const UpdatePlatformException('apk_verification_malformed');
    }
    return valid
        ? const UpdateApkVerification.valid()
        : UpdateApkVerification.invalid(
            value['errorCode'] is String
                ? value['errorCode'] as String
                : 'apk_verification_failed',
          );
  }

  @override
  Future<UpdateInstallResult> installApk(String path) async {
    final raw = await _invokeMap('installApk', <String, Object?>{'path': path});
    final status = raw['status'];
    if (status is! String) {
      throw const UpdatePlatformException('install_result_malformed');
    }
    return switch (status) {
      'started' => const UpdateInstallResult.started(),
      'permission_required' => const UpdateInstallResult.permissionRequired(),
      'canceled' => const UpdateInstallResult.canceled(),
      'failed' => UpdateInstallResult.failed(
        raw['errorCode'] is String
            ? raw['errorCode'] as String
            : 'install_failed',
      ),
      _ => throw const UpdatePlatformException('install_status_unknown'),
    };
  }

  @override
  Future<bool> deleteApk(String path) async {
    final raw = await _invokeMap('deleteApk', <String, Object?>{'path': path});
    final deleted = raw['deleted'];
    if (deleted is! bool) {
      throw const UpdatePlatformException('delete_result_malformed');
    }
    return deleted;
  }

  Future<Map<String, dynamic>> _invokeMap(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(method, arguments);
      if (raw is! Map) {
        throw const UpdatePlatformException('platform_result_malformed');
      }
      return raw.cast<String, dynamic>();
    } on UpdatePlatformException {
      rethrow;
    } on PlatformException catch (error) {
      throw UpdatePlatformException(error.code);
    } on MissingPluginException {
      throw const UpdatePlatformException('platform_unavailable');
    }
  }
}

class UpdatePlatformException implements Exception {
  const UpdatePlatformException(this.code);

  final String code;

  @override
  String toString() => 'UpdatePlatformException($code)';
}
