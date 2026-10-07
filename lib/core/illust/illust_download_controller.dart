import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../download/download_manager.dart';
import '../download/download_request.dart' show DownloadTarget;
import '../download/download_task.dart';
import '../entity/illust_entity.dart';
import '../download/download_providers.dart';
import '../download/illust_download_coordinator.dart';
import '../settings/settings_controller.dart';

/// Per-page download state for the detail download mode, mirroring beta56
/// IllustSaveState and backed by real DownloadManager tasks (R4 — no
/// no-op paths).
enum IllustPageSaveState { none, downloading, error, exist }

/// A whole work's download state; [progress] (0..1) only while downloading.
@immutable
class IllustWorkSaveState {
  const IllustWorkSaveState(this.state, {this.progress});

  final IllustPageSaveState state;
  final double? progress;
}

class _IllustDownloadController {
  _IllustDownloadController(this._ref);

  final Ref _ref;

  DownloadManager get _manager => _ref.watch(downloadManagerProvider);

  /// State for one page index, derived from live manager tasks.
  IllustPageSaveState stateFor(int illustId, int pageIndex) {
    final task = _ref
        .watch(illustDownloadCoordinatorProvider)
        .taskFor(illustId: illustId, pageIndex: pageIndex);
    if (task == null) return IllustPageSaveState.none;
    return _pageState(task.status);
  }

  static IllustPageSaveState _pageState(DownloadStatus status) {
    return switch (status) {
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

  /// Whole-work state for one download button: downloading while any page
  /// is in flight (with the mean progress over all pages), exist once every
  /// page is saved, error when a page failed and none is in flight.
  IllustWorkSaveState workStateFor(IllustEntity entity) {
    final pages = entity.pageCount;
    final states = List.filled(pages, IllustPageSaveState.none);
    final progress = List.filled(pages, 0.0);
    // One pass over the manager's tasks rather than one scan per page.
    for (final task in _manager.tasks) {
      final index = task.pageIndex;
      if (task.illustId != entity.id ||
          task.target != DownloadTarget.illustPage.name ||
          index < 0 ||
          index >= pages) {
        continue;
      }
      states[index] = _pageState(task.status);
      progress[index] = switch (states[index]) {
        IllustPageSaveState.exist => 1,
        IllustPageSaveState.downloading => task.progress ?? 0,
        _ => 0,
      };
    }
    if (states.contains(IllustPageSaveState.downloading)) {
      return IllustWorkSaveState(
        IllustPageSaveState.downloading,
        progress: progress.fold<double>(0, (sum, value) => sum + value) / pages,
      );
    }
    if (pages > 0 && states.every((s) => s == IllustPageSaveState.exist)) {
      return const IllustWorkSaveState(IllustPageSaveState.exist);
    }
    if (states.contains(IllustPageSaveState.error)) {
      return const IllustWorkSaveState(IllustPageSaveState.error);
    }
    return const IllustWorkSaveState(IllustPageSaveState.none);
  }

  /// Submits (or retries) one page; beta56 download(index). Throws
  /// [FormatException] when the work has no usable original URL.
  Future<DownloadTaskSnapshot> download(
    IllustEntity entity,
    int pageIndex,
  ) async {
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
          work: entity,
          pageIndex: pageIndex,
          url: Uri.parse(url),
          namingRule: _ref.read(namingRuleProvider),
        );
  }

  /// Download All (beta56 downloadAll): every page, deduped by the manager.
  Future<DownloadGroupSubmission> downloadAll(IllustEntity entity) async {
    final urls = <String>[
      for (var i = 0; i < entity.pageCount; i++) ?entity.originalUrlAt(i),
    ];
    if (urls.isEmpty) {
      throw const FormatException('work has no original image URL');
    }
    final coordinator = _ref.watch(illustDownloadCoordinatorProvider);
    return coordinator.downloadAllPages(
      work: entity,
      pageUrls: [for (final url in urls) Uri.parse(url)],
      namingRule: _ref.read(namingRuleProvider),
    );
  }
}

final illustDownloadControllerProvider = Provider<_IllustDownloadController>(
  _IllustDownloadController.new,
);
