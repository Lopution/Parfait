import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_entity.dart';
import 'caption_exporter.dart';
import 'download_manager.dart';
import 'download_providers.dart';
import 'download_request.dart';
import 'download_task.dart';
import 'naming_rule.dart';

/// Detail-page download facade (implement.md step 4): single page and
/// Download All submit typed requests; toasts remain at the call site.
class IllustDownloadCoordinator {
  IllustDownloadCoordinator(this._manager, {CaptionExporter? captionExporter})
    : _captionExporter = captionExporter;

  final DownloadManager _manager;
  final CaptionExporter? _captionExporter;

  /// Submits one page. Returns the (deduped) task snapshot; throws
  /// [FormatException] when the URL/extension is unsafe.
  Future<DownloadTaskSnapshot> downloadPage({
    required IllustEntity work,
    required int pageIndex,
    required Uri url,
    NamingRule? namingRule,
  }) async {
    final request = _requestFor(
      work,
      pageIndex: pageIndex,
      url: url,
      namingRule: namingRule,
    );
    final snapshot = _manager.submit(request);
    await _exportCaption(work, request, snapshot);
    return snapshot;
  }

  /// Download All: one request per page URL, page index = list position.
  /// Repeated submissions while tasks are live dedupe to the same tasks.
  Future<List<DownloadTaskSnapshot>> downloadAllPages({
    required IllustEntity work,
    required List<Uri> pageUrls,
    NamingRule? namingRule,
  }) async {
    final requests = [
      for (var i = 0; i < pageUrls.length; i++)
        _requestFor(
          work,
          pageIndex: i,
          url: pageUrls[i],
          namingRule: namingRule,
        ),
    ];
    if (requests.isEmpty) {
      throw const FormatException('work has no downloadable pages');
    }
    final group = _manager.submitGroup(requests);
    final first = _manager.taskById(group.jobIds.first);
    if (first != null) {
      await _exportCaption(work, requests.first, first);
    }
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
            _requestFor(
              work,
              pageIndex: i,
              url: Uri.parse(url),
              namingRule: namingRule,
            ),
    ];
  }

  /// Bulk author download (implement.md step 4): one group containing every
  /// downloadable page of every enumerated work. An empty request set is a
  /// caller-visible error, never a silent no-op.
  Future<DownloadGroupSnapshot> downloadAuthorWorks({
    required List<IllustEntity> works,
    NamingRule? namingRule,
  }) async {
    final requests = authorWorksRequests(works, namingRule: namingRule);
    if (requests.isEmpty) {
      throw const FormatException('author works have no downloadable pages');
    }
    final group = _manager.submitGroup(requests);
    // Caption sidecars ride the same submission; per-work dedupe keeps this
    // idempotent when the same author is re-enqueued later.
    final workById = {for (final work in works) work.id: work};
    final seen = <int>{};
    for (var i = 0; i < requests.length; i++) {
      final request = requests[i];
      if (!seen.add(request.illustId)) continue;
      final work = workById[request.illustId];
      final snapshot = _manager.taskById(group.jobIds[i]);
      if (work == null || snapshot == null) continue;
      await _exportCaption(work, request, snapshot);
    }
    return group;
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

  DownloadRequest _requestFor(
    IllustEntity work, {
    required int pageIndex,
    required Uri url,
    NamingRule? namingRule,
  }) {
    return DownloadRequest(
      illustId: work.id,
      pageIndex: pageIndex,
      url: url,
      target: DownloadTarget.illustPage,
      namingRule: namingRule,
      artist: work.user.name,
      title: work.title,
      authorId: work.user.id,
      totalPages: work.pageCount,
      width: work.width,
      height: work.height,
      date: DateTime.tryParse(work.createDate ?? ''),
    );
  }

  /// Submit-time caption trigger (implement.md step 5). Only illust-page
  /// downloads participate; unowned submissions have no account identity to
  /// dedupe against and skip silently.
  Future<void> _exportCaption(
    IllustEntity work,
    DownloadRequest request,
    DownloadTaskSnapshot snapshot,
  ) async {
    final exporter = _captionExporter;
    final submission = snapshot.submission;
    if (exporter == null || submission == null) return;
    await exporter.export(
      illust: work,
      submission: submission,
      pageZeroName: request.pageZero.displayName,
    );
  }
}

/// Riverpod-facing coordinator.
final illustDownloadCoordinatorProvider = Provider<IllustDownloadCoordinator>(
  (ref) => IllustDownloadCoordinator(
    ref.watch(downloadManagerProvider),
    captionExporter: ref.watch(captionExporterProvider),
  ),
);
