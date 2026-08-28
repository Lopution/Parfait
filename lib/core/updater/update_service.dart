import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'update_download.dart';
import 'update_manifest.dart';
import 'update_models.dart';
import 'update_platform.dart';

export 'update_models.dart';
export 'update_platform.dart';

abstract interface class UpdateManifestTransport {
  Future<UpdateHttpResponse> fetch(Uri uri);
}

class UpdateHttpResponse {
  const UpdateHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final List<int> body;
  final Map<String, String> headers;
}

abstract interface class UpdateSignatureVerifier {
  Future<bool> verify({
    required List<int> message,
    required List<int> signature,
  });
}

class PlatformUpdateSignatureVerifier implements UpdateSignatureVerifier {
  const PlatformUpdateSignatureVerifier(this.platform);

  final UpdatePlatform platform;

  @override
  Future<bool> verify({
    required List<int> message,
    required List<int> signature,
  }) =>
      platform.verifyManifestSignature(message: message, signature: signature);
}

class UpdateService {
  UpdateService({
    required UpdateManifestTransport manifestTransport,
    UpdatePlatform? platform,
    UpdateSignatureVerifier? signatureVerifier,
    UpdateApkDownloader? downloader,
    Uri? manifestUri,
    Uri? signatureUri,
  }) : _manifestTransport = manifestTransport,
       _platform = platform ?? MethodChannelUpdatePlatform(),
       _signatureVerifier =
           signatureVerifier ??
           PlatformUpdateSignatureVerifier(
             platform ?? MethodChannelUpdatePlatform(),
           ),
       _downloader = downloader,
       manifestUri = manifestUri ?? defaultUpdateManifestUri,
       signatureUri = signatureUri ?? defaultUpdateSignatureUri;

  final UpdateManifestTransport _manifestTransport;
  final UpdatePlatform _platform;
  final UpdateSignatureVerifier _signatureVerifier;
  final UpdateApkDownloader? _downloader;
  final Uri manifestUri;
  final Uri signatureUri;
  Future<UpdateCheckResult>? _checkInFlight;
  UpdateCheckResult? _lastCheck;

  UpdateCheckResult? get lastCheck => _lastCheck;

  Future<UpdateApplyResult>? _applyInFlight;

  /// Downloads and hands a verified APK to the platform installer only after
  /// an explicit user confirmation.
  Future<UpdateApplyResult> apply(
    UpdateRelease release, {
    bool confirmed = false,
  }) {
    final inFlight = _applyInFlight;
    if (inFlight != null) return inFlight;
    final future = _applyOnce(release, confirmed: confirmed);
    _applyInFlight = future;
    return future.whenComplete(() {
      if (identical(_applyInFlight, future)) _applyInFlight = null;
    });
  }

  Future<UpdateApplyResult> _applyOnce(
    UpdateRelease release, {
    required bool confirmed,
  }) async {
    if (!confirmed) {
      return const UpdateApplyResult(
        status: UpdateApplyStatus.requiresConfirmation,
        errorCode: 'user_confirmation_required',
      );
    }
    final UpdateCapability capability;
    try {
      capability = await _platform.capability();
    } on UpdatePlatformException catch (error) {
      return UpdateApplyResult(
        status: UpdateApplyStatus.failed,
        errorCode: error.code,
      );
    }
    if (!capability.enabled || capability.flavor != UpdateFlavor.github) {
      return const UpdateApplyResult(status: UpdateApplyStatus.disabled);
    }
    final downloader = _downloader;
    if (downloader == null) {
      return const UpdateApplyResult(
        status: UpdateApplyStatus.failed,
        errorCode: 'downloader_unavailable',
      );
    }
    UpdateApplyResult downloaded;
    try {
      final recovered = await downloader.recover(release);
      downloaded = recovered.errorCode == 'no_recoverable_update'
          ? await downloader.download(release)
          : recovered;
    } on Object catch (error) {
      return UpdateApplyResult(
        status: UpdateApplyStatus.failed,
        errorCode: error is UpdatePlatformException
            ? error.code
            : 'download_failed',
      );
    }
    if (downloaded.status != UpdateApplyStatus.downloaded ||
        downloaded.path == null) {
      return downloaded;
    }
    final installPath = downloaded.path!;
    final UpdateInstallResult install;
    try {
      install = await _platform.installApk(installPath);
    } on Object catch (error) {
      await downloader.cleanup(installPath);
      return UpdateApplyResult(
        status: UpdateApplyStatus.failed,
        path: installPath,
        errorCode: error is UpdatePlatformException
            ? error.code
            : 'install_failed',
      );
    }
    if (install.status == UpdateApplyStatus.canceled ||
        install.status == UpdateApplyStatus.failed) {
      await downloader.cleanup(installPath);
    }
    return UpdateApplyResult(
      status: install.status,
      path: installPath,
      errorCode: install.errorCode,
    );
  }

  /// Reads the compile-time distribution capability without contacting the
  /// update manifest endpoint. F-Droid uses this to render a store-managed
  /// explanation instead of an inert check button.
  Future<UpdateCapability> capability() => _platform.capability();

  /// Requests cancellation of the active streamed download. The downloader
  /// owns the task identity and therefore remains the only layer allowed to
  /// cancel it.
  Future<void> cancel() async {
    final downloader = _downloader;
    if (downloader != null) await downloader.cancel();
  }

  Future<UpdateCheckResult> check({
    UpdateChannel channel = UpdateChannel.stable,
  }) {
    final inFlight = _checkInFlight;
    if (inFlight != null) return inFlight;
    final future = _checkOnce(channel);
    _checkInFlight = future;
    return future.whenComplete(() {
      if (identical(_checkInFlight, future)) _checkInFlight = null;
    });
  }

  Future<UpdateCheckResult> _checkOnce(UpdateChannel requestedChannel) async {
    UpdateCapability capability;
    try {
      capability = await _platform.capability();
    } on UpdatePlatformException catch (error) {
      return _remember(
        UpdateCheckResult(
          status: UpdateCheckStatus.failed,
          errorCode: error.code,
        ),
      );
    }
    if (!capability.enabled || capability.flavor != UpdateFlavor.github) {
      return _remember(const UpdateCheckResult.disabled());
    }

    final UpdatePlatformInfo info;
    try {
      info = await _platform.info();
    } on UpdatePlatformException catch (error) {
      return _remember(
        UpdateCheckResult(
          status: UpdateCheckStatus.failed,
          errorCode: error.code,
        ),
      );
    }
    if (info.packageName != updatePackageName ||
        info.versionCode <= 0 ||
        info.signingCertificateSha256.length != 64) {
      return _remember(
        const UpdateCheckResult(
          status: UpdateCheckStatus.invalid,
          errorCode: 'platform_info_invalid',
        ),
      );
    }

    final UpdateHttpResponse manifestResponse;
    final UpdateHttpResponse signatureResponse;
    try {
      manifestResponse = await _manifestTransport.fetch(manifestUri);
      if (manifestResponse.statusCode == 429) {
        return _remember(
          const UpdateCheckResult(
            status: UpdateCheckStatus.rateLimited,
            errorCode: 'manifest_rate_limited',
          ),
        );
      }
      if (manifestResponse.statusCode != 200 ||
          manifestResponse.body.length > updateManifestMaxBytes) {
        return _remember(
          const UpdateCheckResult(
            status: UpdateCheckStatus.invalid,
            errorCode: 'manifest_http',
          ),
        );
      }
      signatureResponse = await _manifestTransport.fetch(signatureUri);
      if (signatureResponse.statusCode == 429) {
        return _remember(
          const UpdateCheckResult(
            status: UpdateCheckStatus.rateLimited,
            errorCode: 'signature_rate_limited',
          ),
        );
      }
      if (signatureResponse.statusCode != 200 ||
          signatureResponse.body.length > updateSignatureMaxBytes) {
        return _remember(
          const UpdateCheckResult(
            status: UpdateCheckStatus.invalid,
            errorCode: 'signature_http',
          ),
        );
      }
    } on SocketException {
      return _remember(
        const UpdateCheckResult(
          status: UpdateCheckStatus.offline,
          errorCode: 'network',
        ),
      );
    } on TimeoutException {
      return _remember(
        const UpdateCheckResult(
          status: UpdateCheckStatus.offline,
          errorCode: 'timeout',
        ),
      );
    } on UpdateTransportException catch (error) {
      return _remember(
        UpdateCheckResult(
          status: error.statusCode == 429
              ? UpdateCheckStatus.rateLimited
              : UpdateCheckStatus.failed,
          errorCode: error.code,
        ),
      );
    } on Object catch (error) {
      return _remember(
        UpdateCheckResult(
          status: UpdateCheckStatus.failed,
          errorCode: error.runtimeType.toString(),
        ),
      );
    }

    final List<int> signature;
    try {
      final encoded = utf8.decode(signatureResponse.body).trim();
      if (encoded.isEmpty || encoded.length > updateSignatureMaxBytes) {
        throw const FormatException();
      }
      signature = base64Decode(encoded);
      if (signature.length != 64 || base64Encode(signature) != encoded) {
        throw const FormatException();
      }
    } on Object {
      return _remember(
        const UpdateCheckResult(
          status: UpdateCheckStatus.invalid,
          errorCode: 'signature_format',
        ),
      );
    }

    final bool verified;
    try {
      verified = await _signatureVerifier.verify(
        message: manifestResponse.body,
        signature: signature,
      );
    } on Object catch (error) {
      return _remember(
        UpdateCheckResult(
          status: UpdateCheckStatus.invalid,
          errorCode: error is UpdatePlatformException
              ? error.code
              : 'signature_unavailable',
        ),
      );
    }
    if (!verified) {
      return _remember(
        const UpdateCheckResult(
          status: UpdateCheckStatus.invalid,
          errorCode: 'signature_invalid',
        ),
      );
    }

    final UpdateManifest manifest;
    try {
      manifest = UpdateManifest.parse(utf8.decode(manifestResponse.body));
    } on UpdateManifestFormatException catch (error) {
      return _remember(
        UpdateCheckResult(
          status: UpdateCheckStatus.invalid,
          errorCode: error.code,
        ),
      );
    } on FormatException {
      return _remember(
        const UpdateCheckResult(
          status: UpdateCheckStatus.invalid,
          errorCode: 'manifest_encoding',
        ),
      );
    }

    if (manifest.channel == UpdateChannel.beta &&
        requestedChannel == UpdateChannel.stable) {
      return _remember(
        const UpdateCheckResult(
          status: UpdateCheckStatus.prerelease,
          errorCode: 'prerelease',
        ),
      );
    }
    if (manifest.asset.packageName != info.packageName ||
        manifest.asset.signingCertificateSha256 !=
            info.signingCertificateSha256.toLowerCase()) {
      return _remember(
        const UpdateCheckResult(
          status: UpdateCheckStatus.invalid,
          errorCode: 'asset_identity_mismatch',
        ),
      );
    }

    final UpdateVersion currentVersion;
    try {
      currentVersion = UpdateVersion.parse(info.version);
    } on UpdateManifestFormatException {
      return _remember(
        const UpdateCheckResult(
          status: UpdateCheckStatus.invalid,
          errorCode: 'platform_version_invalid',
        ),
      );
    }
    final versionResult = manifest.version.compareTo(currentVersion);
    if (versionResult < 0 ||
        (versionResult == 0 && manifest.versionCode <= info.versionCode)) {
      return _remember(
        const UpdateCheckResult(
          status: UpdateCheckStatus.noUpdate,
          errorCode: 'up_to_date',
        ),
      );
    }
    return _remember(
      UpdateCheckResult(
        status: UpdateCheckStatus.available,
        release: UpdateRelease(
          manifest: manifest,
          rawManifest: List.unmodifiable(manifestResponse.body),
        ),
      ),
    );
  }

  UpdateCheckResult _remember(UpdateCheckResult result) {
    _lastCheck = result;
    return result;
  }
}

/// Production manifest transport. Redirects are manually bounded and every
/// hop stays on the release host allowlist; it never follows arbitrary URLs.
class HttpUpdateManifestTransport implements UpdateManifestTransport {
  HttpUpdateManifestTransport({HttpClient? client})
    : _client = client ?? HttpClient(),
      _ownsClient = client == null;

  final HttpClient _client;
  final bool _ownsClient;

  @override
  Future<UpdateHttpResponse> fetch(Uri uri) async {
    var current = uri;
    for (var hop = 0; hop <= 3; hop++) {
      _validateUri(current);
      final request = await _client
          .getUrl(current)
          .timeout(const Duration(seconds: 20));
      request
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || hop == 3) {
          throw const UpdateTransportException('redirect_rejected');
        }
        current = current.resolve(location);
        continue;
      }
      final body = await _readBounded(response, _responseLimit(current));
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name] = values.join(',');
      });
      return UpdateHttpResponse(
        statusCode: response.statusCode,
        body: body,
        headers: headers,
      );
    }
    throw const UpdateTransportException('redirect_rejected');
  }

  Future<List<int>> _readBounded(
    HttpClientResponse response,
    int maximum,
  ) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    try {
      await for (final chunk in response) {
        total += chunk.length;
        if (total > maximum) {
          throw const UpdateTransportException('response_oversize');
        }
        builder.add(chunk);
      }
    } catch (error, stackTrace) {
      try {
        await response.drain<void>();
      } on Object {
        // Preserve the bounded-read failure; the socket is already closing.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    return builder.takeBytes();
  }

  int _responseLimit(Uri uri) => uri.path.toLowerCase().endsWith('.sig')
      ? updateSignatureMaxBytes
      : updateManifestMaxBytes;

  void _validateUri(Uri uri) {
    if (uri.scheme != 'https' ||
        !updateReleaseHosts.contains(uri.host.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 443)) {
      throw const UpdateTransportException('url_rejected');
    }
  }

  Future<void> dispose() async {
    if (_ownsClient) _client.close(force: true);
  }
}

class UpdateTransportException implements Exception {
  const UpdateTransportException(this.code, {this.statusCode});

  final String code;
  final int? statusCode;

  @override
  String toString() => 'UpdateTransportException($code)';
}
