import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/download/download_manager.dart';
import '../../../core/download/download_task.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/download/illust_download_coordinator.dart';

/// Per-page download state for the detail download mode, mirroring beta56
/// IllustSaveState and backed by real DownloadManager tasks (R4 — no
/// no-op paths).
enum IllustPageSaveState { none, downloading, error, exist }

class IllustDownloadController {
  IllustDownloadController(this._ref);

  final Ref _ref;

  DownloadManager get _manager => _ref.watch(downloadManagerProvider);

  /// State for one page index, derived from live manager tasks.
  IllustPageSaveState stateFor(int illustId, int pageIndex) {
    final task = _ref
        .watch(illustDownloadCoordinatorProvider)
        .taskFor(illustId: illustId, pageIndex: pageIndex);
    if (task == null) return IllustPageSaveState.none;
    return switch (task.status) {
      DownloadStatus.queued ||
      DownloadStatus.running ||
      DownloadStatus.finalizing ||
      DownloadStatus.canceling => IllustPageSaveState.downloading,
      DownloadStatus.failed => IllustPageSaveState.error,
      DownloadStatus.succeeded => IllustPageSaveState.exist,
      DownloadStatus.retryable ||
      DownloadStatus.canceled ||
      DownloadStatus.orphaned => IllustPageSaveState.none,
    };
  }

  /// Submits (or retries) one page; beta56 download(index). Throws
  /// [FormatException] when the work has no usable original URL.
  DownloadTaskSnapshot download(IllustEntity entity, int pageIndex) {
    final url = entity.originalUrlAt(pageIndex);
    if (url == null) {
      throw const FormatException('work has no original image URL');
    }
    // A failed/canceled task must be re-enqueued via retry, not deduped.
    final existing = _ref
        .watch(illustDownloadCoordinatorProvider)
        .taskFor(illustId: entity.id, pageIndex: pageIndex);
    if (existing != null &&
        (existing.status == DownloadStatus.failed ||
            existing.status == DownloadStatus.canceled)) {
      final retried = _manager.retry(existing.id);
      if (retried != null) return retried;
    }
    return _ref
        .watch(illustDownloadCoordinatorProvider)
        .downloadPage(
          illustId: entity.id,
          pageIndex: pageIndex,
          url: Uri.parse(url),
        );
  }

  /// Download All (beta56 downloadAll): every page, deduped by the manager.
  List<DownloadTaskSnapshot> downloadAll(IllustEntity entity) {
    final urls = <String>[
      for (var i = 0; i < entity.pageCount; i++) ?entity.originalUrlAt(i),
    ];
    if (urls.isEmpty) {
      throw const FormatException('work has no original image URL');
    }
    // Retry failed/canceled pages first so Download All from the error state
    // re-enqueues instead of dedupe-skipping.
    final coordinator = _ref.watch(illustDownloadCoordinatorProvider);
    for (var i = 0; i < entity.pageCount; i++) {
      final existing = coordinator.taskFor(illustId: entity.id, pageIndex: i);
      if (existing != null &&
          (existing.status == DownloadStatus.failed ||
              existing.status == DownloadStatus.canceled)) {
        _manager.retry(existing.id);
      }
    }
    return coordinator.downloadAllPages(
      illustId: entity.id,
      pageUrls: [for (final url in urls) Uri.parse(url)],
    );
  }
}

final illustDownloadControllerProvider = Provider<IllustDownloadController>(
  IllustDownloadController.new,
);
