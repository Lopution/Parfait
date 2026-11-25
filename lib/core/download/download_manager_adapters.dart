part of 'download_manager.dart';

class _DownloadOwnershipException implements Exception {
  const _DownloadOwnershipException(this.message);

  final String message;

  @override
  String toString() => 'DownloadOwnershipException: $message';
}

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

class _Job {
  _Job({
    required this.id,
    required this.key,
    required this.request,
    required this.displayName,
    required this.submission,
    required this.owner,
    DownloadTaskSnapshot? snapshot,
  }) : snapshot =
           snapshot ??
           DownloadTaskSnapshot(
             id: id,
             illustId: request.illustId,
             pageIndex: request.pageIndex,
             url: request.url,
             target: request.target.name,
             displayName: displayName,
             status: DownloadStatus.queued,
             submission: submission,
             outputOwner: owner,
           );

  final String id;
  final String key;
  final DownloadRequest request;
  final String displayName;
  final DownloadSubmissionSnapshot submission;
  final DownloadOutputOwner owner;

  DownloadCancelToken cancelToken = DownloadCancelToken();
  DownloadTaskSnapshot snapshot;
  var terminalEmitted = false;
  var cleanupStarted = false;
  int? pendingOutputId;
  var ownerInvalidated = false;

  /// Durable token for preserved partial output (D8); mirrored into every
  /// snapshot via [_update] so the UI sees the same value the record has.
  ResumeAnchor? resumeAnchor;

  /// A pause was requested; the next cancellation unwind preserves bytes
  /// and lands in `retryable` instead of `canceled`.
  var pauseRequested = false;

  void applySnapshot(DownloadTaskSnapshot value) {
    snapshot = value;
  }
}

/// What [DownloadManager.dismissAll] removed, kept so
/// [DownloadManager.restore] can put it back. Opaque outside the manager.
final class DownloadRemoval {
  const DownloadRemoval._(this._jobs);

  final List<_RemovedJob> _jobs;

  /// Ids of the tasks that were removed.
  List<String> get taskIds => [for (final removed in _jobs) removed.job.id];

  int get count => _jobs.length;
  bool get isEmpty => _jobs.isEmpty;
}

/// A removed task and where it sat: its index in the task list and, for a
/// group child, its group (enough to bring the group back), the group's
/// index among groups and the task's position in it.
final class _RemovedJob {
  const _RemovedJob({
    required this.job,
    required this.index,
    required this.group,
  });

  final _Job job;
  final int index;
  final ({
    String id,
    DownloadSubmissionSnapshot submission,
    int index,
    int position,
  })?
  group;
}

class _DownloadGroup {
  _DownloadGroup({
    required this.id,
    required this.jobIds,
    required this.submission,
  });

  final String id;
  final List<String> jobIds;
  final DownloadSubmissionSnapshot submission;
}
