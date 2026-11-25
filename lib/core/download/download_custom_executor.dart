import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;

import '../network/compat/network_contracts.dart';
import 'download_recovery.dart';
import 'download_request.dart';
import 'download_sink.dart';
import 'download_transport.dart';
import 'pixiv_download_transport.dart';

/// Progress callback invoked by a [DownloadTargetExecutor] while synthesizing
/// or writing custom non-HTTP targets inside [DownloadManager].
typedef DownloadTargetProgressCallback =
    void Function({int? receivedBytes, int? totalBytes});

/// Custom execution hook for targets that do not stream directly from a single
/// HTTP GET response (`DownloadTarget.ugoiraGif`, `DownloadTarget.novelTxt`).
typedef DownloadTargetExecutor =
    Future<void> Function({
      required DownloadRequest request,
      required DownloadSubmissionSnapshot snapshot,
      required DownloadSink sink,
      required DownloadCancelToken cancelToken,
      required void Function() checkOwner,
      required DownloadTargetProgressCallback onProgress,
    });

/// Targets executed through [DownloadTargetExecutor] instead of HTTP Range
/// streaming; interrupted attempts always become `orphaned` on recovery.
bool isCustomDownloadTarget(DownloadTarget target) =>
    target == DownloadTarget.ugoiraGif || target == DownloadTarget.novelTxt;

class DownloadStorageException implements Exception {
  const DownloadStorageException(this.message);

  final String message;
}

class DownloadPermissionException implements Exception {
  const DownloadPermissionException(this.message);

  final String message;
}

class DownloadDecodeException implements Exception {
  const DownloadDecodeException(this.message);

  final String message;
}

class DownloadResourceLimitException implements Exception {
  const DownloadResourceLimitException(this.message);

  final String message;
}

/// POSIX errno for a full disk (Linux, Android, macOS).
const int _enospc = 28;

/// Why a write failed, for the message that says so: a download's, a GIF
/// export's, or a novel TXT export's.
DownloadFailureKind classifyDownloadFailure(
  Object error, {
  bool isOwnershipError = false,
}) {
  if (error is DownloadCancelledException) return DownloadFailureKind.canceled;
  if (isOwnershipError) return DownloadFailureKind.ownership;
  if (error is DownloadHttpStatusException) {
    return switch (error.statusCode) {
      401 || 403 => DownloadFailureKind.auth,
      408 || 425 || 500 || 502 || 503 || 504 => DownloadFailureKind.network,
      413 => DownloadFailureKind.resource,
      429 => DownloadFailureKind.rateLimit,
      507 => DownloadFailureKind.storage,
      _ => DownloadFailureKind.unknown,
    };
  }
  if (error is PlatformException) {
    if (_hostFailureKind(error.code) case final kind?) return kind;
  }
  if (error is FileSystemException && error.osError?.errorCode == _enospc) {
    return DownloadFailureKind.noSpace;
  }
  if (error is DownloadStorageException || error is FileSystemException) {
    return DownloadFailureKind.storage;
  }
  if (error is DownloadPermissionException ||
      error.toString().toLowerCase().contains('permission')) {
    return DownloadFailureKind.permission;
  }
  if (error is DownloadDecodeException || error is FormatException) {
    return DownloadFailureKind.decode;
  }
  if (error is DownloadResourceLimitException ||
      error.toString().toLowerCase().contains('out of memory') ||
      error.toString().toLowerCase().contains('limit exceeded')) {
    return DownloadFailureKind.resource;
  }
  if (error is NetworkFailureException ||
      error is DownloadTransportException ||
      error is SocketException ||
      error is TimeoutException) {
    return DownloadFailureKind.network;
  }
  return DownloadFailureKind.unknown;
}

/// The SAF, MediaStore, and iOS Photo Library hosts' `<channel>_<reason>` codes
/// (DROID-02, DL-13).
DownloadFailureKind? _hostFailureKind(String code) => switch (code) {
  'saf_permission' || 'saf_not_found' => DownloadFailureKind.destination,
  'mediastore_permission' ||
  'ios_photo_permission_denied' => DownloadFailureKind.permission,
  'saf_no_space' ||
  'mediastore_no_space' ||
  'ios_photo_no_space' => DownloadFailureKind.noSpace,
  _
      when code.startsWith('saf_') ||
          code.startsWith('mediastore_') ||
          code.startsWith('ios_photo_') =>
    DownloadFailureKind.storage,
  _ => null,
};
