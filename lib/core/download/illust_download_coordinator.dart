import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'download_manager.dart';
import 'download_providers.dart';
import 'download_request.dart';
import 'download_task.dart';

/// Detail-page download facade (implement.md step 4): single page and
/// Download All submit typed requests; toasts remain at the call site.
class IllustDownloadCoordinator {
  IllustDownloadCoordinator(this._manager);

  final DownloadManager _manager;

  /// Submits one page. Returns the (deduped) task snapshot; throws
  /// [FormatException] when the URL/extension is unsafe.
  DownloadTaskSnapshot downloadPage({
    required int illustId,
    required int pageIndex,
    required Uri url,
  }) {
    return _manager.submit(
      DownloadRequest(
        illustId: illustId,
        pageIndex: pageIndex,
        url: url,
        target: DownloadTarget.illustPage,
      ),
    );
  }

  /// Download All: one request per page URL, page index = list position.
  /// Repeated submissions while tasks are live dedupe to the same tasks.
  List<DownloadTaskSnapshot> downloadAllPages({
    required int illustId,
    required List<Uri> pageUrls,
  }) {
    final group = _manager.submitGroup([
      for (var i = 0; i < pageUrls.length; i++)
        DownloadRequest(
          illustId: illustId,
          pageIndex: i,
          url: pageUrls[i],
          target: DownloadTarget.illustPage,
        ),
    ]);
    return [for (final id in group.jobIds) _manager.taskById(id)!];
  }

  DownloadTaskSnapshot? taskFor({
    required int illustId,
    required int pageIndex,
  }) {
    for (final task in _manager.tasks) {
      if (task.illustId == illustId &&
          task.pageIndex == pageIndex &&
          task.target == DownloadTarget.illustPage.name) {
        return task;
      }
    }
    return null;
  }
}

/// Riverpod-facing coordinator.
final illustDownloadCoordinatorProvider = Provider<IllustDownloadCoordinator>(
  (ref) => IllustDownloadCoordinator(ref.watch(downloadManagerProvider)),
);
