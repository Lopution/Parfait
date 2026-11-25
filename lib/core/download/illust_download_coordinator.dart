import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_entity.dart';
import '../series/series_models.dart';
import '../series/series_repository.dart';
import '../series/series_store.dart';
import '../settings/settings_controller.dart';
import '../settings/settings_enums.dart';
import 'caption_exporter.dart';
import 'download_manager.dart';
import 'download_providers.dart';
import 'download_request.dart';
import 'download_subfolders.dart';
import 'download_task.dart';
import 'naming_rule.dart';

typedef _ResolvedSeriesMeta = ({String? title, int? order, int? total});

/// Detail-page download facade: single page and
/// Download All submit typed requests; toasts remain at the call site.
class IllustDownloadCoordinator {
  IllustDownloadCoordinator(
    this._manager, {
    CaptionExporter? captionExporter,
    DownloadSubfolderMode Function()? readSubfolderMode,
    bool Function()? readMultiPageSubfolder,
    bool Function()? readPadPageNumbers,
    IllustSeriesEntity? Function(int seriesId)? lookupSeries,
    Future<IllustSeriesContextResult?> Function(int illustId)?
    resolveSeriesContext,
  }) : _captionExporter = captionExporter,
       _readSubfolderMode = readSubfolderMode,
       _readMultiPageSubfolder = readMultiPageSubfolder,
       _readPadPageNumbers = readPadPageNumbers,
       _lookupSeries = lookupSeries,
       _resolveSeriesContext = resolveSeriesContext;

  final DownloadManager _manager;
  final CaptionExporter? _captionExporter;
  final DownloadSubfolderMode Function()? _readSubfolderMode;
  final bool Function()? _readMultiPageSubfolder;
  final bool Function()? _readPadPageNumbers;
  final IllustSeriesEntity? Function(int seriesId)? _lookupSeries;
  final Future<IllustSeriesContextResult?> Function(int illustId)?
  _resolveSeriesContext;

  /// Submits one page. Returns the (deduped) task snapshot; throws
  /// [FormatException] when the URL/extension is unsafe or the work is ugoira.
  Future<DownloadTaskSnapshot> downloadPage({
    required IllustEntity work,
    required int pageIndex,
    required Uri url,
    NamingRule? namingRule,
    DownloadSubfolderMode? subfolderMode,
    bool? multiPageSubfolder,
    bool? padPageNumbers,
  }) async {
    if (work.isUgoira) {
      throw const FormatException('ugoira works require GIF export');
    }
    final effectiveSubfolder = _effectiveSubfolderMode(subfolderMode);
    final effectiveMultiPage = _effectiveMultiPageSubfolder(multiPageSubfolder);
    final effectivePadding = _effectivePadPageNumbers(padPageNumbers);
    final series = await _resolveSeriesForSingleWork(
      work,
      namingRule: namingRule,
      subfolderMode: effectiveSubfolder,
    );
    final request = _requestFor(
      work,
      pageIndex: pageIndex,
      url: url,
      namingRule: namingRule,
      subfolderMode: effectiveSubfolder,
      multiPageSubfolder: effectiveMultiPage,
      padPageNumbers: effectivePadding,
      series: series,
    );
    final snapshot = _manager.submit(request);
    await _exportCaption(work, request, snapshot);
    return snapshot;
  }

  /// Download All: one request per page URL, page index = list position.
  /// Repeated submissions while tasks are live dedupe to the same tasks.
  /// Rejects ugoira works so callers never save static cover JPEGs.
  Future<DownloadGroupSubmission> downloadAllPages({
    required IllustEntity work,
    required List<Uri> pageUrls,
    NamingRule? namingRule,
    DownloadSubfolderMode? subfolderMode,
    bool? multiPageSubfolder,
    bool? padPageNumbers,
  }) async {
    if (work.isUgoira) {
      throw const FormatException('ugoira works require GIF export');
    }
    if (pageUrls.isEmpty) {
      throw const FormatException('work has no downloadable pages');
    }
    final effectiveSubfolder = _effectiveSubfolderMode(subfolderMode);
    final effectiveMultiPage = _effectiveMultiPageSubfolder(multiPageSubfolder);
    final effectivePadding = _effectivePadPageNumbers(padPageNumbers);
    final series = await _resolveSeriesForSingleWork(
      work,
      namingRule: namingRule,
      subfolderMode: effectiveSubfolder,
    );
    final requests = [
      for (var i = 0; i < pageUrls.length; i++)
        _requestFor(
          work,
          pageIndex: i,
          url: pageUrls[i],
          namingRule: namingRule,
          subfolderMode: effectiveSubfolder,
          multiPageSubfolder: effectiveMultiPage,
          padPageNumbers: effectivePadding,
          series: series,
        ),
    ];
    final submission = _manager.submitGroup(requests);
    final first = submission.tasks.first;
    if (submission.group != null) {
      await _exportCaption(work, requests.first, first);
    }
    return submission;
  }

  /// Submits a unified `DownloadTarget.ugoiraGif` job into [DownloadManager]
  /// carrying all naming metadata, subfolder hierarchy, and caption sidecar.
  Future<DownloadTaskSnapshot> downloadUgoiraGif({
    required IllustEntity work,
    NamingRule? namingRule,
    DownloadSubfolderMode? subfolderMode,
    bool? padPageNumbers,
  }) async {
    final effectiveSubfolder = _effectiveSubfolderMode(subfolderMode);
    final effectivePadding = _effectivePadPageNumbers(padPageNumbers);
    final series = await _resolveSeriesForSingleWork(
      work,
      namingRule: namingRule,
      subfolderMode: effectiveSubfolder,
    );
    final request = _ugoiraRequestFor(
      work,
      namingRule: namingRule,
      subfolderMode: effectiveSubfolder,
      padPageNumbers: effectivePadding,
      series: series,
    );
    final snapshot = _manager.submit(request);
    await _exportCaption(work, request, snapshot);
    return snapshot;
  }

  /// Per-page and optional ugoira requests a bulk author submission needs.
  List<DownloadRequest> authorWorksRequests(
    List<IllustEntity> works, {
    List<IllustEntity> ugoiraWorks = const [],
    NamingRule? namingRule,
    DownloadSubfolderMode? subfolderMode,
    bool? multiPageSubfolder,
    bool? padPageNumbers,
  }) {
    final effectiveSubfolder = _effectiveSubfolderMode(subfolderMode);
    final effectiveMultiPage = _effectiveMultiPageSubfolder(multiPageSubfolder);
    final effectivePadding = _effectivePadPageNumbers(padPageNumbers);
    return [
      for (final work in works)
        if (!work.isUgoira)
          for (var i = 0; i < work.pageCount; i++)
            if (work.originalUrlAt(i) case final url?)
              _requestFor(
                work,
                pageIndex: i,
                url: Uri.parse(url),
                namingRule: namingRule,
                subfolderMode: effectiveSubfolder,
                multiPageSubfolder: effectiveMultiPage,
                padPageNumbers: effectivePadding,
                series: _warmSeriesFor(work),
              ),
      for (final ugoira in ugoiraWorks)
        _ugoiraRequestFor(
          ugoira,
          namingRule: namingRule,
          subfolderMode: effectiveSubfolder,
          padPageNumbers: effectivePadding,
          series: _warmSeriesFor(ugoira),
        ),
    ];
  }

  /// Bulk author download: one group containing every downloadable static page
  /// plus any opted-in ugoira works. An empty request set is a caller-visible
  /// error, never a silent no-op.
  Future<DownloadGroupSubmission> downloadAuthorWorks({
    required List<IllustEntity> works,
    List<IllustEntity> ugoiraWorks = const [],
    NamingRule? namingRule,
    DownloadSubfolderMode? subfolderMode,
    bool? multiPageSubfolder,
    bool? padPageNumbers,
  }) async {
    final requests = authorWorksRequests(
      works,
      ugoiraWorks: ugoiraWorks,
      namingRule: namingRule,
      subfolderMode: subfolderMode,
      multiPageSubfolder: multiPageSubfolder,
      padPageNumbers: padPageNumbers,
    );
    if (requests.isEmpty) {
      throw const FormatException('author works have no downloadable pages');
    }
    final submission = _manager.submitGroup(requests);
    // Caption sidecars ride the same submission; per-work dedupe keeps this
    // idempotent when the same author is re-enqueued later.
    final workById = {
      for (final work in works) work.id: work,
      for (final ugoira in ugoiraWorks) ugoira.id: ugoira,
    };
    final seen = <int>{};
    if (submission.group == null) return submission;
    for (var i = 0; i < requests.length; i++) {
      final request = requests[i];
      if (!seen.add(request.illustId)) continue;
      final work = workById[request.illustId];
      final snapshot = submission.tasks[i];
      if (work == null) continue;
      await _exportCaption(work, request, snapshot);
    }
    return submission;
  }

  DownloadTaskSnapshot? ugoiraTaskFor(int illustId) {
    for (final task in _manager.tasks) {
      if (task.illustId == illustId &&
          task.target == DownloadTarget.ugoiraGif.name) {
        return task;
      }
    }
    return null;
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

  DownloadSubfolderMode _effectiveSubfolderMode(
    DownloadSubfolderMode? override,
  ) => override ?? _readSubfolderMode?.call() ?? DownloadSubfolderMode.none;

  bool _effectiveMultiPageSubfolder(bool? override) =>
      override ?? _readMultiPageSubfolder?.call() ?? false;

  bool _effectivePadPageNumbers(bool? override) =>
      override ?? _readPadPageNumbers?.call() ?? false;

  _ResolvedSeriesMeta _warmSeriesFor(IllustEntity work) {
    final seriesId = work.seriesId;
    final stored = seriesId == null ? null : _lookupSeries?.call(seriesId);
    final title = _nonEmpty(work.seriesTitle) ?? _nonEmpty(stored?.title);
    final workCount = stored?.workCount;
    final total = workCount != null && workCount > 0 ? workCount : null;
    return (title: title, order: null, total: total);
  }

  Future<_ResolvedSeriesMeta> _resolveSeriesForSingleWork(
    IllustEntity work, {
    required NamingRule? namingRule,
    required DownloadSubfolderMode subfolderMode,
  }) async {
    final warm = _warmSeriesFor(work);
    final seriesId = work.seriesId;
    final fetcher = _resolveSeriesContext;
    if (seriesId == null || fetcher == null) return warm;
    final template = namingRule?.preset == NamingPreset.custom
        ? (namingRule?.template ?? '')
        : '';
    final needsOrder = template.contains('{series_order}');
    final needsTotal = template.contains('{chapters}') && warm.total == null;
    final needsTitle =
        warm.title == null &&
        (subfolderMode == DownloadSubfolderMode.byArtistAndSeries ||
            template.contains('{series}'));
    if (!needsOrder && !needsTotal && !needsTitle) return warm;
    try {
      final result = await fetcher(work.id);
      if (result == null) return warm;
      final title = warm.title ?? _nonEmpty(result.detail?.title);
      final order = result.context?.contentOrder;
      final detailWorkCount = result.detail?.workCount;
      final total =
          warm.total ??
          (detailWorkCount != null && detailWorkCount > 0
              ? detailWorkCount
              : null);
      return (title: title, order: order, total: total);
    } on Object {
      // Series metadata lookup is best-effort; never block a work download.
      return warm;
    }
  }

  static String? _nonEmpty(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  DownloadRequest _requestFor(
    IllustEntity work, {
    required int pageIndex,
    required Uri url,
    required DownloadSubfolderMode subfolderMode,
    required bool multiPageSubfolder,
    required bool padPageNumbers,
    required _ResolvedSeriesMeta series,
    NamingRule? namingRule,
  }) {
    final subdirectories = resolveWorkSubdirectories(
      mode: subfolderMode,
      multiPageSubfolder: multiPageSubfolder,
      illustId: work.id,
      pageCount: work.pageCount,
      artist: work.user.name,
      authorId: work.user.id,
      seriesTitle: series.title,
      seriesId: work.seriesId,
    );
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
      seriesTitle: series.title,
      seriesOrder: series.order,
      seriesTotal: series.total,
      date: DateTime.tryParse(work.createDate ?? ''),
      thumbnailUrl: work.squareUrlAt(pageIndex),
      subdirectories: subdirectories,
      padPageNumbers: padPageNumbers,
    );
  }

  DownloadRequest _ugoiraRequestFor(
    IllustEntity work, {
    required DownloadSubfolderMode subfolderMode,
    required bool padPageNumbers,
    required _ResolvedSeriesMeta series,
    NamingRule? namingRule,
  }) {
    final subdirectories = resolveWorkSubdirectories(
      mode: subfolderMode,
      multiPageSubfolder: false,
      illustId: work.id,
      pageCount: 1,
      artist: work.user.name,
      authorId: work.user.id,
      seriesTitle: series.title,
      seriesId: work.seriesId,
    );
    return DownloadRequest(
      illustId: work.id,
      pageIndex: 0,
      url: Uri.parse('https://i.pximg.net/ugoira/${work.id}.gif'),
      target: DownloadTarget.ugoiraGif,
      namingRule: namingRule,
      artist: work.user.name,
      title: work.title,
      authorId: work.user.id,
      totalPages: work.pageCount,
      width: work.width,
      height: work.height,
      seriesTitle: series.title,
      seriesOrder: series.order,
      seriesTotal: series.total,
      date: DateTime.tryParse(work.createDate ?? ''),
      thumbnailUrl: work.squareUrlAt(0),
      subdirectories: subdirectories,
      padPageNumbers: padPageNumbers,
    );
  }

  /// Submit-time caption trigger. Only illust-page
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
    readSubfolderMode: () => ref.read(downloadSubfolderModeProvider),
    readMultiPageSubfolder: () => ref.read(downloadMultiPageSubfolderProvider),
    readPadPageNumbers: () => ref.read(downloadPadPageNumbersProvider),
    lookupSeries: (seriesId) => ref.read(illustSeriesStoreProvider)[seriesId],
    resolveSeriesContext: (illustId) async {
      final result = await ref
          .read(seriesRepositoryProvider)
          .fetchIllustSeriesContext(illustId);
      final detail = result.detail;
      if (detail != null) {
        ref.read(illustSeriesStoreProvider.notifier).mergeAll([detail]);
      }
      return result;
    },
  ),
);
