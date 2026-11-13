part of 'download_manager.dart';

class _DownloadOwnershipException implements Exception {
  const _DownloadOwnershipException(this.message);

  final String message;

  @override
  String toString() => 'DownloadOwnershipException: $message';
}

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

/// Why a write failed, for the message that says so: a download's, or a
/// GIF export's.
DownloadFailureKind classifyDownloadFailure(Object error) {
  if (error is DownloadCancelledException) return DownloadFailureKind.canceled;
  if (error is _DownloadOwnershipException) {
    return DownloadFailureKind.ownership;
  }
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
  // A timeout here is the transport's: no body byte within its idle budget.
  if (error is NetworkFailureException ||
      error is DownloadTransportException ||
      error is SocketException ||
      error is TimeoutException) {
    return DownloadFailureKind.network;
  }
  return DownloadFailureKind.unknown;
}

/// POSIX errno for a full disk (Linux, Android, macOS).
const _enospc = 28;

/// The SAF and MediaStore hosts' `<channel>_<reason>` codes (DROID-02).
/// A SAF permission failure means the folder grant is gone, and a missing
/// SAF document means the folder or the file in it is gone: either way the
/// folder has to be picked again. MediaStore's permission is the app's
/// storage permission.
DownloadFailureKind? _hostFailureKind(String code) => switch (code) {
  'saf_permission' || 'saf_not_found' => DownloadFailureKind.destination,
  'mediastore_permission' => DownloadFailureKind.permission,
  'saf_no_space' || 'mediastore_no_space' => DownloadFailureKind.noSpace,
  _ when code.startsWith('saf_') || code.startsWith('mediastore_') =>
    DownloadFailureKind.storage,
  _ => null,
};

String _safeError(Object error) {
  if (error is DownloadHttpStatusException) {
    return 'HTTP ${error.statusCode} download failure';
  }
  return CrashLog.describe(error);
}

Duration? _retryAfter(DownloadResponse response) {
  if (response is! DownloadResponseMetadata) return null;
  return _parseRetryAfter((response as DownloadResponseMetadata).headers);
}

Duration? _retryAfterFromError(Object error) {
  if (error is DownloadHttpStatusException) return error.retryAfter;
  return null;
}

Duration? _parseRetryAfter(Map<String, String> headers) {
  String? value;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'retry-after') {
      value = entry.value.trim();
      break;
    }
  }
  if (value == null || value.isEmpty) return null;
  final seconds = int.tryParse(value);
  if (seconds != null && seconds >= 0 && seconds <= 86400) {
    return Duration(seconds: seconds);
  }
  final date = DateTime.tryParse(value);
  if (date == null) return null;
  final delta = date.toUtc().difference(DateTime.now().toUtc());
  return delta.isNegative ? Duration.zero : delta;
}

RangeResponse _rangeResponse(DownloadResponse response) => RangeResponse(
  statusCode: response.statusCode,
  headers: switch (response) {
    final DownloadResponseMetadata metadata => {
      for (final entry in metadata.headers.entries)
        entry.key.toLowerCase(): entry.value,
    },
    _ => const {},
  },
  body: response.stream,
  close: response.close,
);

/// A sized 206 continued when it stalls. It reads like one 206 for the rest
/// of the file: [contentLength] counts from the resume offset to the end
/// and [headers] are the first response's.
class _ContinuedDownloadResponse
    implements DownloadResponse, DownloadResponseMetadata {
  _ContinuedDownloadResponse(
    this._fetch,
    RangeResponse first, {
    required this.contentLength,
    required NetworkCancelSignal cancel,
  }) : headers = first.headers,
       stream = _fetch
           .continueFrom(first, cancel: cancel)
           .handleError(
             (Object _) => throw const DownloadCancelledException(),
             test: (error) => error is ContinuedFetchCancelled,
           );

  final ContinuedFetch _fetch;

  @override
  int get statusCode => 206;

  @override
  final int contentLength;

  @override
  final Map<String, String> headers;

  @override
  final Stream<List<int>> stream;

  @override
  Future<void> close() async => _fetch.close();
}

/// A download response served from a file already in the image disk cache.
/// `offset` mirrors an HTTP Range continuation: the stream yields only the
/// bytes the resumed sink is missing, and [contentLength] reports the tail
/// length so total/received accounting matches the transport path.
class _FileDownloadResponse implements DownloadResponse {
  _FileDownloadResponse(this._file, this._offset);

  final File _file;
  final int _offset;

  @override
  int get statusCode => 200;

  int? _contentLength;

  @override
  int? get contentLength => _contentLength;

  @override
  Stream<List<int>> get stream => _file.openRead(_offset);

  /// Resolves the tail length lazily is not possible here — the manager
  /// reads [contentLength] before listening, so length is captured eagerly
  /// by [open].
  static Future<_FileDownloadResponse> open(File file, int offset) async {
    final length = await file.length();
    final clamped = offset.clamp(0, length);
    return _FileDownloadResponse(file, clamped)
      .._contentLength = length - clamped;
  }

  @override
  Future<void> close() async {}
}
