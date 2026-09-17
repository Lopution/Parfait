import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_entity.dart';
import 'download_manager.dart';
import 'download_providers.dart';
import 'download_request.dart';
import 'download_task.dart';
import 'naming_rule.dart';

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
    NamingRule? namingRule,
    String? artist,
    String? title,
  }) {
    return _manager.submit(
      DownloadRequest(
        illustId: illustId,
        pageIndex: pageIndex,
        url: url,
        target: DownloadTarget.illustPage,
        namingRule: namingRule,
        artist: artist,
        title: title,
      ),
    );
  }

  /// Download All: one request per page URL, page index = list position.
  /// Repeated submissions while tasks are live dedupe to the same tasks.
  List<DownloadTaskSnapshot> downloadAllPages({
    required int illustId,
    required List<Uri> pageUrls,
    NamingRule? namingRule,
    String? artist,
    String? title,
  }) {
    final group = _manager.submitGroup([
      for (var i = 0; i < pageUrls.length; i++)
        DownloadRequest(
          illustId: illustId,
          pageIndex: i,
          url: pageUrls[i],
          target: DownloadTarget.illustPage,
          namingRule: namingRule,
          artist: artist,
          title: title,
        ),
    ]);
    return [for (final id in group.jobIds) _manager.taskById(id)!];
  }

  /// Per-page requests a bulk author submission needs. Exposed so the
  /// confirmation dialog can show the real page count before enqueueing;
  /// works with no usable original URL contribute nothing.
  List<DownloadRequest> authorWorksRequests(
    List<IllustEntity> works, {
    NamingRule? namingRule,
  }) {
    return [
      for (final work in works)
        for (var i = 0; i < work.pageCount; i++)
          if (work.originalUrlAt(i) case final url?)
            DownloadRequest(
              illustId: work.id,
              pageIndex: i,
              url: Uri.parse(url),
              target: DownloadTarget.illustPage,
              namingRule: namingRule,
              artist: work.user.name,
              title: work.title,
            ),
    ];
  }

  /// Bulk author download (implement.md step 4): one group containing every
  /// downloadable page of every enumerated work. An empty request set is a
  /// caller-visible error, never a silent no-op.
  DownloadGroupSnapshot downloadAuthorWorks({
    required List<IllustEntity> works,
    NamingRule? namingRule,
  }) {
    final requests = authorWorksRequests(works, namingRule: namingRule);
    if (requests.isEmpty) {
      throw const FormatException('author works have no downloadable pages');
    }
    return _manager.submitGroup(requests);
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
