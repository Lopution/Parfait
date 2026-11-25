import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../backup/backup_service.dart';
import '../download/caption_exporter.dart' show captionFits;
import '../download/download_manager.dart';
import '../download/download_providers.dart';
import '../download/download_request.dart';
import '../download/download_subfolders.dart';
import '../download/novel_txt_formatter.dart';
import '../localnovel/local_novel_repository.dart';
import '../localnovel/local_novel_store.dart';
import '../network/api_error.dart';
import '../network/pixiv_http_client.dart';
import '../platform/app_storage_paths.dart';
import '../platform/desktop_file_sink.dart' show sanitizeDesktopFileName;
import '../platform/platform_caps.dart';
import '../settings/settings_controller.dart';
import 'novel_entity.dart';
import 'novel_repository.dart';

/// Outcome of exporting a single novel or local TXT.
enum NovelTxtExportOutcome { queued, shared, androidFolderRequired }

/// Outcome of saving or exporting a novel series.
class NovelSeriesBatchResult {
  const NovelSeriesBatchResult({
    required this.processed,
    required this.skipped,
    this.outcome = NovelTxtExportOutcome.queued,
    this.localNovel,
  });

  final int processed;
  final int skipped;
  final NovelTxtExportOutcome outcome;
  final LocalNovel? localNovel;
}

/// High-level coordinator for caching Pixiv novels into [LocalNovelStore] and
/// exporting UTF-8 `.txt` files across desktop, Android SAF, and iOS share
/// sheet.
class NovelDownloadCoordinator {
  NovelDownloadCoordinator(this._ref);

  final Ref _ref;

  /// Fetches full novel text if [novel] is a sparse feed entity, then saves it
  /// into the offline [LocalNovelStore] preserving `[chapter:...]` and
  /// `[newpage]` markers.
  Future<LocalNovel> saveNovelOffline(
    NovelEntity novel, {
    CancelToken? cancelToken,
  }) async {
    final full = await _ensureFullNovel(novel, cancelToken: cancelToken);
    if (!full.contentAvailable) {
      throw const FormatException('novel content is unavailable');
    }
    final body = formatPixivNovelOfflineBody(full);
    return _ref
        .read(localNovelStoreProvider.notifier)
        .savePixivNovel(
          title: full.title,
          author: full.user.name,
          text: body,
          pixivNovelId: full.id,
          pixivSeriesId: full.seriesId,
          pixivSeriesTitle: full.seriesTitle,
        );
  }

  /// Paginates all chapters of [seriesId], skips restricted or unviewable
  /// episodes, and stores the merged series in [LocalNovelStore].
  Future<NovelSeriesBatchResult> saveSeriesOffline(
    int seriesId, {
    CancelToken? cancelToken,
  }) async {
    final fetched = await _fetchSeriesChapters(
      seriesId,
      cancelToken: cancelToken,
    );
    if (fetched.chapters.isEmpty) {
      return NovelSeriesBatchResult(processed: 0, skipped: fetched.skipped);
    }
    final detail = fetched.detail;
    final first = fetched.chapters.first;
    final title = (fetched.seriesTitle?.isNotEmpty ?? false)
        ? fetched.seriesTitle!
        : (first.seriesTitle ?? first.title);
    final detailUser = detail?.user;
    final author = (detailUser != null && detailUser.name.isNotEmpty)
        ? detailUser.name
        : first.user.name;
    final body = formatPixivNovelSeriesTxt(
      seriesTitle: title,
      authorName: author,
      authorId: detailUser?.id ?? first.user.id,
      seriesId: seriesId,
      chapters: fetched.chapters,
      caption: detail?.caption,
    );
    final saved = await _ref
        .read(localNovelStoreProvider.notifier)
        .savePixivNovel(
          title: title,
          author: author,
          text: body,
          pixivSeriesId: seriesId,
          pixivSeriesTitle: title,
        );
    return NovelSeriesBatchResult(
      processed: fetched.chapters.length,
      skipped: fetched.skipped,
      localNovel: saved,
    );
  }

  /// Exports one Pixiv novel as UTF-8 `.txt`: queues in [DownloadManager] on
  /// desktop/Android SAF, opens iOS share sheet on iOS, or returns
  /// [NovelTxtExportOutcome.androidFolderRequired] on Android album targets.
  Future<NovelTxtExportOutcome> exportNovelTxt(
    NovelEntity novel, {
    int? seriesOrder,
    int? seriesTotal,
    Rect? sharePositionOrigin,
    CancelToken? cancelToken,
  }) async {
    final guard = _checkPlatformExportDestination();
    if (guard != null) return guard;

    final full = await _ensureFullNovel(novel, cancelToken: cancelToken);
    if (!full.contentAvailable) {
      throw const FormatException('novel content is unavailable');
    }
    final text = formatPixivNovelTxt(full);
    final request = _buildNovelRequest(
      novel: full,
      seriesOrder: seriesOrder,
      seriesTotal: seriesTotal,
    );
    return _dispatchTxt(
      request: request,
      text: text,
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  /// Exports a Pixiv novel series as UTF-8 `.txt`, either merged into one file
  /// (`merged: true`) or one queued `.txt` per viewable chapter.
  Future<NovelSeriesBatchResult> exportSeriesTxt(
    int seriesId, {
    required bool merged,
    Rect? sharePositionOrigin,
    CancelToken? cancelToken,
  }) async {
    final guard = _checkPlatformExportDestination();
    if (guard != null) {
      return NovelSeriesBatchResult(processed: 0, skipped: 0, outcome: guard);
    }

    final fetched = await _fetchSeriesChapters(
      seriesId,
      cancelToken: cancelToken,
    );
    if (fetched.chapters.isEmpty) {
      return NovelSeriesBatchResult(processed: 0, skipped: fetched.skipped);
    }
    final detail = fetched.detail;
    final first = fetched.chapters.first;
    final seriesTitle = (fetched.seriesTitle?.isNotEmpty ?? false)
        ? fetched.seriesTitle!
        : (first.seriesTitle ?? first.title);
    final detailUser = detail?.user;
    final authorName = (detailUser != null && detailUser.name.isNotEmpty)
        ? detailUser.name
        : first.user.name;
    final authorId = detailUser?.id ?? first.user.id;
    final total = fetched.chapters.length;

    if (merged || _ref.read(platformCapsProvider).isIOS) {
      final text = formatPixivNovelSeriesTxt(
        seriesTitle: seriesTitle,
        authorName: authorName,
        authorId: authorId,
        seriesId: seriesId,
        chapters: fetched.chapters,
        caption: detail?.caption,
      );
      final url = Uri.parse('https://i.pximg.net/novel/series_$seriesId.txt');
      final request = DownloadRequest(
        illustId: seriesId,
        pageIndex: 0,
        url: url,
        target: DownloadTarget.novelTxt,
        namingRule: _ref.read(namingRuleProvider),
        artist: authorName,
        title: seriesTitle,
        authorId: authorId,
        seriesTitle: seriesTitle,
        seriesTotal: total,
        subdirectories: _subdirectoriesFor(
          artist: authorName,
          authorId: authorId,
          seriesTitle: seriesTitle,
          seriesId: seriesId,
          id: seriesId,
        ),
        padPageNumbers: _ref.read(downloadPadPageNumbersProvider),
      );
      final outcome = await _dispatchTxt(
        request: request,
        text: text,
        sharePositionOrigin: sharePositionOrigin,
      );
      return NovelSeriesBatchResult(
        processed: total,
        skipped: fetched.skipped,
        outcome: outcome,
      );
    }

    final payloads = _ref.read(novelTxtPayloadStoreProvider);
    final requests = <DownloadRequest>[];
    for (var i = 0; i < fetched.chapters.length; i++) {
      final chapter = fetched.chapters[i];
      final req = _buildNovelRequest(
        novel: chapter,
        seriesTitleOverride: seriesTitle,
        seriesOrder: i + 1,
        seriesTotal: total,
      );
      payloads.put(req.url, formatPixivNovelTxt(chapter));
      requests.add(req);
    }
    _ref.read(downloadManagerProvider).submitGroup(requests);
    return NovelSeriesBatchResult(
      processed: requests.length,
      skipped: fetched.skipped,
      outcome: NovelTxtExportOutcome.queued,
    );
  }

  /// Exports an already-saved [LocalNovel] from the offline library as `.txt`.
  Future<NovelTxtExportOutcome> exportLocalNovelTxt(
    LocalNovel novel, {
    Rect? sharePositionOrigin,
  }) async {
    final guard = _checkPlatformExportDestination();
    if (guard != null) return guard;

    final text = await novel.file.readAsString();
    final id = novel.pixivNovelId ?? novel.pixivSeriesId ?? novel.id;
    final url = Uri.parse('https://i.pximg.net/novel/local_${novel.id}.txt');
    final request = DownloadRequest(
      illustId: id > 0 ? id : 1,
      pageIndex: 0,
      url: url,
      target: DownloadTarget.novelTxt,
      namingRule: _ref.read(namingRuleProvider),
      artist: novel.author,
      title: novel.title,
      seriesTitle: novel.pixivSeriesTitle,
      subdirectories: _subdirectoriesFor(
        artist: novel.author,
        seriesTitle: novel.pixivSeriesTitle,
        seriesId: novel.pixivSeriesId,
        id: id > 0 ? id : 1,
      ),
      padPageNumbers: _ref.read(downloadPadPageNumbersProvider),
    );
    return _dispatchTxt(
      request: request,
      text: text,
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  NovelTxtExportOutcome? _checkPlatformExportDestination() {
    final caps = _ref.read(platformCapsProvider);
    if (caps.isIOS) return null;
    if (caps.supportsMediaStore &&
        !captionFits(_ref.read(downloadDestinationProvider), isAndroid: true)) {
      return NovelTxtExportOutcome.androidFolderRequired;
    }
    return null;
  }

  Future<NovelTxtExportOutcome> _dispatchTxt({
    required DownloadRequest request,
    required String text,
    Rect? sharePositionOrigin,
  }) async {
    final shareExporter = _ref.read(backupShareExporterProvider);
    if (shareExporter != null) {
      final tempRoot = await AppStoragePaths.active.resolveTempDir();
      final dir = Directory(p.join(tempRoot.path, 'novel_exports'));
      await dir.create(recursive: true);
      final safeName = sanitizeDesktopFileName(
        request.displayName,
        fallback: 'novel.txt',
      );
      final file = File(p.join(dir.path, safeName));
      await file.writeAsString(text, flush: true);
      await shareExporter.shareFile(
        path: file.path,
        fileName: safeName,
        mimeType: 'text/plain',
        sharePositionOrigin: sharePositionOrigin,
      );
      return NovelTxtExportOutcome.shared;
    }
    _ref.read(novelTxtPayloadStoreProvider).put(request.url, text);
    _ref.read(downloadManagerProvider).submit(request);
    return NovelTxtExportOutcome.queued;
  }

  DownloadRequest _buildNovelRequest({
    required NovelEntity novel,
    String? seriesTitleOverride,
    int? seriesOrder,
    int? seriesTotal,
  }) {
    final seriesTitle = seriesTitleOverride ?? novel.seriesTitle;
    return DownloadRequest(
      illustId: novel.id,
      pageIndex: 0,
      url: Uri.parse('https://i.pximg.net/novel/${novel.id}.txt'),
      target: DownloadTarget.novelTxt,
      namingRule: _ref.read(namingRuleProvider),
      artist: novel.user.name,
      title: novel.title,
      authorId: novel.user.id,
      seriesTitle: seriesTitle,
      seriesOrder: seriesOrder,
      seriesTotal: seriesTotal,
      date: DateTime.tryParse(novel.createDate ?? ''),
      thumbnailUrl: novel.coverImageUrl,
      subdirectories: _subdirectoriesFor(
        artist: novel.user.name,
        authorId: novel.user.id,
        seriesTitle: seriesTitle,
        seriesId: novel.seriesId,
        id: novel.id,
      ),
      padPageNumbers: _ref.read(downloadPadPageNumbersProvider),
    );
  }

  List<String> _subdirectoriesFor({
    required int id,
    String? artist,
    int? authorId,
    String? seriesTitle,
    int? seriesId,
  }) => resolveWorkSubdirectories(
    mode: _ref.read(downloadSubfolderModeProvider),
    multiPageSubfolder: false,
    illustId: id,
    pageCount: 1,
    artist: artist,
    authorId: authorId,
    seriesTitle: seriesTitle,
    seriesId: seriesId,
  );

  Future<NovelEntity> _ensureFullNovel(
    NovelEntity novel, {
    CancelToken? cancelToken,
  }) async {
    if (novel.contentAvailable &&
        (novel.markup != null || novel.paragraphs.isNotEmpty)) {
      return novel;
    }
    return _ref
        .read(novelRepositoryProvider)
        .fetchDetail(novel.id, cancelToken: cancelToken);
  }

  Future<
    ({
      String? seriesTitle,
      NovelSeriesDetail? detail,
      List<NovelEntity> chapters,
      int skipped,
    })
  >
  _fetchSeriesChapters(int seriesId, {CancelToken? cancelToken}) async {
    final repo = _ref.read(novelRepositoryProvider);
    String? seriesTitle;
    NovelSeriesDetail? detail;
    final entries = <NovelSeriesEntry>[];
    String? cursor;
    var pages = 0;
    const maxPages = 50;
    do {
      final page = await repo.fetchSeries(
        seriesId,
        cursor: cursor,
        cancelToken: cancelToken,
      );
      if (seriesTitle == null && (page.title?.isNotEmpty ?? false)) {
        seriesTitle = page.title;
      }
      detail ??= page.detail;
      entries.addAll(page.entries);
      cursor = page.nextUrl;
      pages++;
    } while (cursor != null && pages < maxPages);

    final chapters = <NovelEntity>[];
    var skipped = 0;
    for (final entry in entries) {
      if (cancelToken?.isCancelled ?? false) {
        throw const ApiCancelled();
      }
      if (!entry.viewable) {
        skipped++;
        continue;
      }
      try {
        final full = await repo.fetchDetail(entry.id, cancelToken: cancelToken);
        if (full.isRestricted || !full.contentAvailable) {
          skipped++;
        } else {
          chapters.add(full);
        }
      } on ApiHttpError catch (error) {
        // Only genuinely unavailable chapters (forbidden/deleted) count as
        // skipped; cancellation, network, auth, rate-limit, and parse failures
        // propagate so the user never receives a silently truncated export.
        if (error.statusCode == 403 || error.statusCode == 404) {
          skipped++;
        } else {
          rethrow;
        }
      }
    }
    return (
      seriesTitle: seriesTitle,
      detail: detail,
      chapters: chapters,
      skipped: skipped,
    );
  }
}

final novelDownloadCoordinatorProvider = Provider<NovelDownloadCoordinator>(
  (ref) => NovelDownloadCoordinator(ref),
);
