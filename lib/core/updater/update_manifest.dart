import 'dart:convert';

import 'package:meta/meta.dart';

import '../download/download_request.dart';
import 'update_models.dart';

const int updateManifestMaxBytes = 64 * 1024;
const int updateSignatureMaxBytes = 4 * 1024;
const int updateAssetMaxBytes = 200 * 1024 * 1024;
const String updateRepository = 'Lopution/Pixiv-func';
const String updatePackageName = 'io.github.lopution.pixivfunc';

const Set<String> updateReleaseHosts = kUpdateDownloadHosts;

final Uri defaultUpdateManifestUri = Uri.parse(
  'https://github.com/Lopution/Pixiv-func/releases/latest/download/update-manifest.json',
);

final Uri defaultUpdateSignatureUri = Uri.parse(
  'https://github.com/Lopution/Pixiv-func/releases/latest/download/update-manifest.sig',
);

@immutable
class UpdateVersion implements UpdateVersionLike {
  UpdateVersion._({
    required this.major,
    required this.minor,
    required this.patch,
    required List<String> prerelease,
    required this.build,
  }) : prerelease = List.unmodifiable(prerelease);

  factory UpdateVersion.parse(String value) {
    if (value.length > 128) {
      throw const UpdateManifestFormatException('version');
    }
    final match = RegExp(
      r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$',
    ).firstMatch(value);
    if (match == null) {
      throw const UpdateManifestFormatException('version');
    }
    final prerelease = match.group(4)?.split('.') ?? const <String>[];
    if (prerelease.any((part) {
      if (part.isEmpty) return true;
      if (part.length > 64) return true;
      return RegExp(r'^0[0-9]+$').hasMatch(part);
    })) {
      throw const UpdateManifestFormatException('version');
    }
    final build = match.group(5)?.split('.') ?? const <String>[];
    return UpdateVersion._(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      patch: int.parse(match.group(3)!),
      prerelease: prerelease,
      build: build,
    );
  }

  final int major;
  final int minor;
  final int patch;
  final List<String> prerelease;
  final List<String> build;

  @override
  bool get isPrerelease => prerelease.isNotEmpty;

  @override
  int compareTo(UpdateVersionLike other) {
    if (other is! UpdateVersion) return 0;
    final core = _compareCore(other);
    if (core != 0) return core;
    if (isPrerelease != other.isPrerelease) return isPrerelease ? -1 : 1;
    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      final left = prerelease[i];
      final right = other.prerelease[i];
      final leftNumber = int.tryParse(left);
      final rightNumber = int.tryParse(right);
      if (leftNumber != null && rightNumber != null) {
        final result = leftNumber.compareTo(rightNumber);
        if (result != 0) return result;
      } else if (leftNumber != null) {
        return -1;
      } else if (rightNumber != null) {
        return 1;
      } else {
        final result = left.compareTo(right);
        if (result != 0) return result;
      }
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }

  int _compareCore(UpdateVersion other) {
    final majorResult = major.compareTo(other.major);
    if (majorResult != 0) return majorResult;
    final minorResult = minor.compareTo(other.minor);
    if (minorResult != 0) return minorResult;
    return patch.compareTo(other.patch);
  }

  @override
  String toString() {
    final suffix = isPrerelease ? '-${prerelease.join('.')}' : '';
    final buildSuffix = build.isEmpty ? '' : '+${build.join('.')}';
    return '$major.$minor.$patch$suffix$buildSuffix';
  }
}

@immutable
class UpdateManifest implements UpdateManifestLike {
  const UpdateManifest({
    required this.repository,
    required this.tag,
    required this.channel,
    required this.version,
    required this.versionCode,
    required this.asset,
  });

  factory UpdateManifest.parse(String raw) {
    if (utf8.encode(raw).length > updateManifestMaxBytes) {
      throw const UpdateManifestFormatException('manifest_size');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const UpdateManifestFormatException('manifest_json');
    }
    final map = _object(decoded, 'manifest');
    _exactKeys(map, const {
      'schema',
      'repository',
      'tag',
      'channel',
      'version',
      'versionCode',
      'asset',
    }, 'manifest_keys');
    if (map['schema'] != 1) {
      throw const UpdateManifestFormatException('schema');
    }
    final repository = _string(map['repository'], 'repository');
    if (repository != updateRepository) {
      throw const UpdateManifestFormatException('repository');
    }
    final tag = _string(map['tag'], 'tag');
    final versionText = _string(map['version'], 'version');
    final version = UpdateVersion.parse(versionText);
    if (tag != 'v$versionText') {
      throw const UpdateManifestFormatException('tag');
    }
    final channelText = _string(map['channel'], 'channel');
    final channel = switch (channelText) {
      'stable' => UpdateChannel.stable,
      'beta' => UpdateChannel.beta,
      _ => throw const UpdateManifestFormatException('channel'),
    };
    final versionCode = _positiveInt(map['versionCode'], 'version_code');
    final asset = _parseAsset(map['asset']);
    return UpdateManifest(
      repository: repository,
      tag: tag,
      channel: channel,
      version: version,
      versionCode: versionCode,
      asset: asset,
    );
  }

  @override
  final String repository;
  @override
  final String tag;
  @override
  final UpdateChannel channel;
  @override
  final UpdateVersion version;
  @override
  final int versionCode;
  @override
  final UpdateReleaseAsset asset;
}

UpdateReleaseAsset _parseAsset(Object? value) {
  final map = _object(value, 'asset');
  _exactKeys(map, const {
    'url',
    'size',
    'sha256',
    'packageName',
    'signingCertificateSha256',
  }, 'asset_keys');
  final url = _strictHttpsUri(_string(map['url'], 'asset_url'));
  if (!isStrictUpdateAssetUrl(url)) {
    throw const UpdateManifestFormatException('asset_url');
  }
  final exactSize = _positiveInt(map['size'], 'asset_size');
  if (exactSize > updateAssetMaxBytes) {
    throw const UpdateManifestFormatException('asset_size');
  }
  final sha256 = _lowerHex(_string(map['sha256'], 'asset_sha256'), 64);
  final packageName = _string(map['packageName'], 'package_name');
  if (packageName != updatePackageName) {
    throw const UpdateManifestFormatException('package_name');
  }
  final certificate = _lowerHex(
    _string(map['signingCertificateSha256'], 'signing_certificate'),
    64,
  );
  return UpdateReleaseAsset(
    url: url,
    exactSize: exactSize,
    sha256: sha256,
    packageName: packageName,
    signingCertificateSha256: certificate,
  );
}

Uri _strictHttpsUri(String raw) {
  if (raw.length > 2048) {
    throw const UpdateManifestFormatException('url_size');
  }
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (uri.hasPort && uri.port != 443) ||
      uri.host.codeUnits.any((value) => value > 0x7f) ||
      uri.host.endsWith('.')) {
    throw const UpdateManifestFormatException('url');
  }
  return uri;
}

Map<String, dynamic> _object(Object? value, String code) {
  if (value is! Map<String, dynamic>) {
    throw UpdateManifestFormatException(code);
  }
  return value;
}

void _exactKeys(Map<String, dynamic> map, Set<String> allowed, String code) {
  if (map.keys.any((key) => !allowed.contains(key)) ||
      allowed.any((key) => !map.containsKey(key))) {
    throw UpdateManifestFormatException(code);
  }
}

String _string(Object? value, String code) {
  if (value is! String || value.isEmpty || value.length > 2048) {
    throw UpdateManifestFormatException(code);
  }
  return value;
}

int _positiveInt(Object? value, String code) {
  if (value is! int || value <= 0 || value > 0x7fffffff) {
    throw UpdateManifestFormatException(code);
  }
  return value;
}

String _lowerHex(String value, int length) {
  if (value.length != length || value != value.toLowerCase()) {
    throw const UpdateManifestFormatException('hex');
  }
  if (!RegExp(r'^[0-9a-f]+$').hasMatch(value)) {
    throw const UpdateManifestFormatException('hex');
  }
  return value;
}

class UpdateManifestFormatException implements Exception {
  const UpdateManifestFormatException(this.code);

  final String code;

  @override
  String toString() => 'UpdateManifestFormatException($code)';
}
