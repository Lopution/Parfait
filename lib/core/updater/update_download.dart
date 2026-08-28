import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../download/download_manager.dart';
import '../download/download_sink.dart';
import '../download/download_task.dart';
import '../download/download_request.dart';
import 'update_manifest.dart';
import 'update_models.dart';
import 'update_platform.dart';

abstract interface class UpdateApkDownloader {
  Future<UpdateApplyResult> download(UpdateRelease release);

  Future<bool> cleanup(String path);

  Future<UpdateApplyResult> recover(UpdateRelease release);

  Future<void> cancel();
}

/// Persists only the exact update identity and owned path. It has no request
/// headers, credentials or arbitrary external URLs beyond the signed asset.
@immutable
class UpdateDownloadState {
  const UpdateDownloadState({
    required this.downloadId,
    required this.version,
    required this.versionCode,
    required this.assetUrl,
    required this.exactSize,
    required this.sha256,
    required this.packageName,
    required this.signingCertificateSha256,
    required this.path,
  });

  final String downloadId;
  final String version;
  final int versionCode;
  final String assetUrl;
  final int exactSize;
  final String sha256;
  final String packageName;
  final String signingCertificateSha256;
  final String path;

  Map<String, Object?> toJson() => <String, Object?>{
    'downloadId': downloadId,
    'version': version,
    'versionCode': versionCode,
    'assetUrl': assetUrl,
    'exactSize': exactSize,
    'sha256': sha256,
    'packageName': packageName,
    'signingCertificateSha256': signingCertificateSha256,
    'path': path,
  };

  static UpdateDownloadState parse(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('update state is not an object');
    }
    const expectedKeys = <String>{
      'downloadId',
      'version',
      'versionCode',
      'assetUrl',
      'exactSize',
      'sha256',
      'packageName',
      'signingCertificateSha256',
      'path',
    };
    if (value.keys.any((key) => !expectedKeys.contains(key)) ||
        expectedKeys.any((key) => !value.containsKey(key))) {
      throw const FormatException('update state keys');
    }
    final strings = <String>[
      'downloadId',
      'version',
      'assetUrl',
      'sha256',
      'packageName',
      'signingCertificateSha256',
      'path',
    ];
    for (final key in strings) {
      final field = value[key];
      if (field is! String || field.isEmpty || field.length > 2048) {
        throw FormatException('update state field $key');
      }
    }
    final ints = <String>['versionCode', 'exactSize'];
    for (final key in ints) {
      final field = value[key];
      if (field is! int || field <= 0 || field > updateAssetMaxBytes) {
        throw FormatException('update state field $key');
      }
    }
    final sha = value['sha256'] as String;
    final certificate = value['signingCertificateSha256'] as String;
    if (!_isHex(sha, 64) ||
        !_isHex(certificate, 64) ||
        value['packageName'] != updatePackageName) {
      throw const FormatException('update state digest');
    }
    UpdateVersion.parse(value['version'] as String);
    final assetUri = Uri.tryParse(value['assetUrl'] as String);
    if (assetUri == null || !isStrictUpdateAssetUrl(assetUri)) {
      throw const FormatException('update state URL');
    }
    return UpdateDownloadState(
      downloadId: value['downloadId'] as String,
      version: value['version'] as String,
      versionCode: value['versionCode'] as int,
      assetUrl: value['assetUrl'] as String,
      exactSize: value['exactSize'] as int,
      sha256: sha,
      packageName: value['packageName'] as String,
      signingCertificateSha256: certificate,
      path: value['path'] as String,
    );
  }
}

abstract interface class UpdateDownloadStateStore {
  Future<UpdateDownloadState?> read();

  Future<void> write(UpdateDownloadState state);

  Future<void> clear();
}

class MemoryUpdateDownloadStateStore implements UpdateDownloadStateStore {
  UpdateDownloadState? value;

  @override
  Future<UpdateDownloadState?> read() async => value;

  @override
  Future<void> write(UpdateDownloadState state) async {
    value = state;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class PreferencesUpdateDownloadStateStore implements UpdateDownloadStateStore {
  PreferencesUpdateDownloadStateStore({
    SharedPreferencesAsync? preferences,
    this.storageKey = 'pixivfunc.update.download.v1',
  }) : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;
  final String storageKey;

  @override
  Future<UpdateDownloadState?> read() async {
    final raw = await _preferences.getString(storageKey);
    if (raw == null || raw.length > 16 * 1024) return null;
    try {
      return UpdateDownloadState.parse(jsonDecode(raw));
    } on Object {
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(UpdateDownloadState state) async {
    final raw = jsonEncode(state.toJson());
    if (raw.length > 16 * 1024) {
      throw const FormatException('update state oversize');
    }
    await _preferences.setString(storageKey, raw);
  }

  @override
  Future<void> clear() => _preferences.remove(storageKey);
}

/// File sink used only for the owned app-private update directory. Bytes are
/// streamed to disk and never accumulated as one APK-sized List in memory.
class UpdateFileSinkFactory implements DownloadSinkFactory {
  UpdateFileSinkFactory(this.directory);

  final Directory directory;

  @override
  Future<DownloadSink> begin(
    DownloadRequest request,
    String displayName,
  ) async {
    if (request.target != DownloadTarget.updaterApk) {
      throw const FormatException('update sink received non-APK target');
    }
    validateDisplayName(displayName);
    await directory.create(recursive: true);
    return _UpdateFileSink(File(p.join(directory.path, displayName)));
  }
}

class _UpdateFileSink implements DownloadSink {
  _UpdateFileSink(this.file);

  final File file;
  IOSink? _output;
  var _closed = false;

  Future<IOSink> _open() async {
    final current = _output;
    if (current != null) return current;
    if (_closed) throw StateError('update sink is closed');
    final output = file.openWrite(mode: FileMode.write);
    _output = output;
    return output;
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (bytes.isEmpty) return;
    (await _open()).add(bytes);
  }

  @override
  Future<String> finalize() async {
    if (_closed) throw StateError('update sink is closed');
    _closed = true;
    await _output?.flush();
    await _output?.close();
    return file.path;
  }

  @override
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    try {
      await _output?.close();
    } finally {
      if (file.existsSync()) await file.delete();
    }
  }
}

class UpdateDownloadCoordinator implements UpdateApkDownloader {
  UpdateDownloadCoordinator({
    required DownloadManager manager,
    required UpdatePlatform platform,
    required Directory directory,
    required UpdateDownloadStateStore stateStore,
  }) : _manager = manager,
       _platform = platform,
       _directory = directory,
       _stateStore = stateStore;

  final DownloadManager _manager;
  final UpdatePlatform _platform;
  final Directory _directory;
  final UpdateDownloadStateStore _stateStore;
  Future<UpdateApplyResult>? _downloadInFlight;
  String? _activeDownloadId;
  var _cancelRequested = false;

  @override
  Future<UpdateApplyResult> download(UpdateRelease release) {
    final inFlight = _downloadInFlight;
    if (inFlight != null) return inFlight;
    _cancelRequested = false;
    final future = _downloadOnce(release);
    _downloadInFlight = future;
    return future.whenComplete(() {
      if (identical(_downloadInFlight, future)) _downloadInFlight = null;
    });
  }

  Future<UpdateApplyResult> _downloadOnce(UpdateRelease release) async {
    final asset = release.manifest.asset;
    final request = DownloadRequest(
      illustId: release.manifest.versionCode,
      pageIndex: 0,
      url: asset.url,
      target: DownloadTarget.updaterApk,
    );
    final file = File(p.join(_directory.path, request.displayName));
    await _deleteOwnedFile(file);
    await _stateStore.clear();
    final baseState = UpdateDownloadState(
      downloadId: '',
      version: release.manifest.version.toString(),
      versionCode: release.manifest.versionCode,
      assetUrl: asset.url.toString(),
      exactSize: asset.exactSize,
      sha256: asset.sha256,
      packageName: asset.packageName,
      signingCertificateSha256: asset.signingCertificateSha256,
      path: file.path,
    );
    try {
      final terminal = _manager.events.firstWhere(
        (event) =>
            event.snapshot.target == DownloadTarget.updaterApk.name &&
            event.snapshot.url == request.url,
      );
      var submitted = _manager.submit(request);
      if (submitted.status == DownloadStatus.retryable) {
        submitted =
            _manager.retry(submitted.id) ??
            (throw StateError('updater retry could not be restored'));
      }
      _activeDownloadId = submitted.id;
      if (_cancelRequested) await _manager.cancel(submitted.id);
      await _stateStore.write(
        UpdateDownloadState(
          downloadId: submitted.id,
          version: baseState.version,
          versionCode: baseState.versionCode,
          assetUrl: baseState.assetUrl,
          exactSize: baseState.exactSize,
          sha256: baseState.sha256,
          packageName: baseState.packageName,
          signingCertificateSha256: baseState.signingCertificateSha256,
          path: baseState.path,
        ),
      );
      final event = await terminal;
      if (event.kind != DownloadEventKind.succeeded) {
        await _stateStore.clear();
        await _deleteOwnedFile(file);
        return UpdateApplyResult(
          status: event.kind == DownloadEventKind.canceled
              ? UpdateApplyStatus.canceled
              : UpdateApplyStatus.failed,
          errorCode: event.snapshot.failureKind?.name ?? 'download_failed',
        );
      }
      final integrity = await _verifyFile(file, asset);
      if (!integrity.valid) {
        await _stateStore.clear();
        await _deleteOwnedFile(file);
        return UpdateApplyResult(
          status: UpdateApplyStatus.failed,
          errorCode: integrity.errorCode,
        );
      }
      final platformVerification = await _platform.verifyApk(
        path: file.path,
        asset: asset,
      );
      if (!platformVerification.valid) {
        await _stateStore.clear();
        await _deleteOwnedFile(file);
        return UpdateApplyResult(
          status: UpdateApplyStatus.failed,
          errorCode:
              platformVerification.errorCode ?? 'apk_verification_failed',
        );
      }
      await _stateStore.write(baseState.copyWith(downloadId: submitted.id));
      return UpdateApplyResult(
        status: UpdateApplyStatus.downloaded,
        path: file.path,
      );
    } on Object catch (error) {
      await _stateStore.clear();
      await _deleteOwnedFile(file);
      return UpdateApplyResult(
        status: UpdateApplyStatus.failed,
        errorCode: error is FormatException
            ? error.message
            : error.runtimeType.toString(),
      );
    } finally {
      _activeDownloadId = null;
    }
  }

  @override
  Future<void> cancel() async {
    _cancelRequested = true;
    final id = _activeDownloadId;
    if (id != null) await _manager.cancel(id);
  }

  @override
  Future<UpdateApplyResult> recover(UpdateRelease release) async {
    final state = await _stateStore.read();
    if (state == null) {
      return const UpdateApplyResult(
        status: UpdateApplyStatus.failed,
        errorCode: 'no_recoverable_update',
      );
    }
    final asset = release.manifest.asset;
    final expectedVersion = release.manifest.version.toString();
    final matches =
        state.version == expectedVersion &&
        state.versionCode == release.manifest.versionCode &&
        state.assetUrl == asset.url.toString() &&
        state.exactSize == asset.exactSize &&
        state.sha256 == asset.sha256 &&
        state.packageName == asset.packageName &&
        state.signingCertificateSha256 == asset.signingCertificateSha256;
    final file = File(state.path);
    if (!matches || !_isOwnedPath(file)) {
      await cleanup(state.path);
      await _stateStore.clear();
      return const UpdateApplyResult(
        status: UpdateApplyStatus.failed,
        errorCode: 'recovery_identity_mismatch',
      );
    }
    var task = _manager.taskById(state.downloadId);
    if (task == null ||
        task.target != DownloadTarget.updaterApk.name ||
        task.url != asset.url ||
        task.displayName != file.path.split(p.separator).last) {
      await cleanup(state.path);
      await _stateStore.clear();
      return const UpdateApplyResult(
        status: UpdateApplyStatus.failed,
        errorCode: 'no_recoverable_update',
      );
    }
    if (task.status == DownloadStatus.retryable) {
      task = _manager.retry(task.id);
      if (task == null) {
        await cleanup(state.path);
        await _stateStore.clear();
        return const UpdateApplyResult(
          status: UpdateApplyStatus.failed,
          errorCode: 'no_recoverable_update',
        );
      }
      await _stateStore.write(state.copyWith(downloadId: task.id));
    }
    if (!isTerminal(task.status)) {
      final event = await _manager.events.firstWhere(
        (event) => event.snapshot.id == task!.id,
      );
      if (event.kind != DownloadEventKind.succeeded) {
        await cleanup(file.path);
        await _stateStore.clear();
        return const UpdateApplyResult(
          status: UpdateApplyStatus.failed,
          errorCode: 'download_failed',
        );
      }
    } else if (task.status != DownloadStatus.succeeded) {
      await cleanup(file.path);
      await _stateStore.clear();
      return const UpdateApplyResult(
        status: UpdateApplyStatus.failed,
        errorCode: 'no_recoverable_update',
      );
    }
    final integrity = await _verifyFile(file, asset);
    if (!integrity.valid) {
      await cleanup(file.path);
      await _stateStore.clear();
      return UpdateApplyResult(
        status: UpdateApplyStatus.failed,
        errorCode: integrity.errorCode,
      );
    }
    final platformVerification = await _platform.verifyApk(
      path: file.path,
      asset: asset,
    );
    if (!platformVerification.valid) {
      await cleanup(file.path);
      await _stateStore.clear();
      return UpdateApplyResult(
        status: UpdateApplyStatus.failed,
        errorCode: platformVerification.errorCode ?? 'apk_verification_failed',
      );
    }
    return UpdateApplyResult(
      status: UpdateApplyStatus.downloaded,
      path: file.path,
    );
  }

  @override
  Future<bool> cleanup(String path) async {
    final file = File(path);
    if (!_isOwnedPath(file)) return false;
    var deleted = true;
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      deleted = false;
    }
    if (deleted) {
      final state = await _stateStore.read();
      if (state?.path == file.path) await _stateStore.clear();
    }
    return deleted;
  }

  bool _isOwnedPath(File file) {
    final base = p.normalize(_directory.absolute.path);
    final target = p.normalize(file.absolute.path);
    return target.startsWith('$base${p.separator}') &&
        p.basename(target).isNotEmpty &&
        !p.basename(target).contains('..');
  }

  Future<void> _deleteOwnedFile(File file) async {
    if (_isOwnedPath(file) && file.existsSync()) await file.delete();
  }

  Future<UpdateApkVerification> _verifyFile(
    File file,
    UpdateReleaseAsset asset,
  ) async {
    if (!file.existsSync()) {
      return const UpdateApkVerification.invalid('apk_missing');
    }
    final length = await file.length();
    if (length != asset.exactSize) {
      return const UpdateApkVerification.invalid('apk_size_mismatch');
    }
    final digestSink = _DigestSink();
    final input = sha256.startChunkedConversion(digestSink);
    try {
      await for (final chunk in file.openRead()) {
        input.add(chunk);
      }
      input.close();
    } on Object {
      return const UpdateApkVerification.invalid('apk_read_failed');
    }
    final digest = digestSink.value?.toString();
    if (digest == null) {
      return const UpdateApkVerification.invalid('apk_hash_unavailable');
    }
    if (digest != asset.sha256) {
      return const UpdateApkVerification.invalid('apk_hash_mismatch');
    }
    return const UpdateApkVerification.valid();
  }
}

extension on UpdateDownloadState {
  UpdateDownloadState copyWith({String? downloadId}) => UpdateDownloadState(
    downloadId: downloadId ?? this.downloadId,
    version: version,
    versionCode: versionCode,
    assetUrl: assetUrl,
    exactSize: exactSize,
    sha256: this.sha256,
    packageName: packageName,
    signingCertificateSha256: signingCertificateSha256,
    path: path,
  );
}

bool _isHex(String value, int length) =>
    value.length == length && RegExp(r'^[0-9a-f]+$').hasMatch(value);

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest event) {
    value = event;
  }

  @override
  void close() {}
}
