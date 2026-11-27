import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_error.dart';
import '../network/pixiv_http_client.dart';
import '../novel/novel_entity.dart';
import '../novel/novel_repository.dart';
import 'download_custom_executor.dart';
import 'download_recovery.dart';
import 'download_request.dart';
import 'download_sink.dart';
import 'download_transport.dart';
import 'pixiv_download_transport.dart' show DownloadCancelledException;

/// Formats a single Pixiv [NovelEntity] as UTF-8 plain text with a metadata
/// header matching `CaptionExporter` and body text preserving `[chapter:...]`
/// headings and `[newpage]` separators.
String formatPixivNovelTxt(NovelEntity novel) {
  final buffer = StringBuffer()
    ..write('标题：${novel.title}\n\n')
    ..write('作者：${novel.user.name}\n\n')
    ..write('作者ID：${novel.user.id}\n\n')
    ..write('作品ID：${novel.id}\n\n')
    ..write('作品链接：https://www.pixiv.net/novel/show.php?id=${novel.id}\n\n');
  if (novel.seriesTitle != null && novel.seriesTitle!.isNotEmpty) {
    buffer.write('系列：${novel.seriesTitle}\n\n');
  }
  final tags = [
    for (final tag in novel.tags)
      if (tag.name.isNotEmpty) tag.name,
  ];
  if (tags.isNotEmpty) {
    buffer.write('标签：${tags.join(', ')}\n\n');
  }
  final caption = novel.caption.replaceAll(
    RegExp(r'<br\s*/?>', caseSensitive: false),
    '\n',
  );
  if (caption.trim().isNotEmpty) {
    buffer.write('简介：\n$caption\n\n');
  }
  buffer
    ..write('---\n\n')
    ..write(_bodyOf(novel))
    ..write('\n');
  return buffer.toString();
}

/// Formats a merged Pixiv novel series as one UTF-8 text document with
/// `[chapter:...]` markers per episode so offline chapter navigation works
/// seamlessly when saved into the local novel library or exported as `.txt`.
String formatPixivNovelSeriesTxt({
  required String seriesTitle,
  required String authorName,
  required int authorId,
  required int seriesId,
  required List<NovelEntity> chapters,
  String? caption,
}) {
  final buffer = StringBuffer()
    ..write('系列：$seriesTitle\n\n')
    ..write('作者：$authorName\n\n')
    ..write('作者ID：$authorId\n\n')
    ..write('系列ID：$seriesId\n\n')
    ..write('系列链接：https://www.pixiv.net/novel/series/$seriesId\n\n');
  final cleanCaption = (caption ?? '').replaceAll(
    RegExp(r'<br\s*/?>', caseSensitive: false),
    '\n',
  );
  if (cleanCaption.trim().isNotEmpty) {
    buffer.write('简介：\n$cleanCaption\n\n');
  }
  buffer.write('---\n\n');
  for (var i = 0; i < chapters.length; i++) {
    final chapter = chapters[i];
    if (i > 0) buffer.write('\n[newpage]\n');
    buffer
      ..write('[chapter:${chapter.title}]\n')
      ..write(_bodyOf(chapter))
      ..write('\n');
  }
  return buffer.toString();
}

/// Builds raw body text suitable for offline `LocalNovelReaderPage` parsing,
/// preserving Pixiv `[chapter:...]` and `[newpage]` markers.
String formatPixivNovelOfflineBody(NovelEntity novel) => _bodyOf(novel);

String _bodyOf(NovelEntity novel) {
  final markup = novel.markup;
  if (markup != null && markup.tokens.isNotEmpty) {
    final buffer = StringBuffer();
    for (final token in markup.tokens) {
      buffer.write(token.rawText);
    }
    return buffer.toString();
  }
  return [for (final p in novel.paragraphs) p.text].join('\n');
}

/// In-memory payload registry for queued `DownloadTarget.novelTxt` exports
/// (keyed by synthetic request URL string so retries within the process reuse
/// pre-assembled merged series or local TXT bytes; single Pixiv novels can
/// also fall back to fetching from `NovelRepository`).
class NovelTxtPayloadStore {
  final Map<String, String> _payloads = {};

  void put(Uri url, String text) {
    _payloads[url.toString()] = text;
  }

  String? get(Uri url) => _payloads[url.toString()];

  void remove(Uri url) => _payloads.remove(url.toString());
}

/// Paginates all chapters of [seriesId], skipping restricted or unavailable
/// episodes while propagating cancellation, network, auth, and rate-limit errors.
Future<
  ({
    String? seriesTitle,
    NovelSeriesDetail? detail,
    List<NovelEntity> chapters,
    int skipped,
  })
>
fetchPixivNovelSeriesChapters({
  required int seriesId,
  required Future<NovelSeriesPage> Function(
    int seriesId, {
    String? cursor,
    CancelToken? cancelToken,
  })
  fetchSeries,
  required Future<NovelEntity> Function(int novelId, {CancelToken? cancelToken})
  fetchDetail,
  CancelToken? cancelToken,
}) async {
  String? seriesTitle;
  NovelSeriesDetail? detail;
  final entries = <NovelSeriesEntry>[];
  String? cursor;
  var pages = 0;
  const maxPages = 50;
  do {
    final page = await fetchSeries(
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
      final full = await fetchDetail(entry.id, cancelToken: cancelToken);
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

/// Fetches and formats a merged Pixiv novel series TXT payload for cold-restart
/// download retries.
Future<String> buildPixivNovelSeriesTxt({
  required int seriesId,
  required Future<NovelSeriesPage> Function(
    int seriesId, {
    String? cursor,
    CancelToken? cancelToken,
  })
  fetchSeries,
  required Future<NovelEntity> Function(int novelId, {CancelToken? cancelToken})
  fetchDetail,
  CancelToken? cancelToken,
}) async {
  final fetched = await fetchPixivNovelSeriesChapters(
    seriesId: seriesId,
    fetchSeries: fetchSeries,
    fetchDetail: fetchDetail,
    cancelToken: cancelToken,
  );
  if (fetched.chapters.isEmpty) {
    throw const FormatException('novel series content is unavailable');
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
  return formatPixivNovelSeriesTxt(
    seriesTitle: seriesTitle,
    authorName: authorName,
    authorId: detailUser?.id ?? first.user.id,
    seriesId: seriesId,
    chapters: fetched.chapters,
    caption: detail?.caption,
  );
}

final novelTxtPayloadStoreProvider = Provider<NovelTxtPayloadStore>(
  (ref) => NovelTxtPayloadStore(),
);

/// Executes [DownloadTarget.novelTxt] jobs inside [DownloadManager], writing
/// UTF-8 `.txt` bytes in chunks to the owned [DownloadSink].
class NovelTxtDownloadExecutor {
  NovelTxtDownloadExecutor({
    required NovelTxtPayloadStore payloads,
    Future<NovelEntity> Function(int novelId)? fetchNovelDetail,
    Future<String> Function(int seriesId)? fetchSeriesTxt,
    Future<String?> Function(int localId)? readLocalNovelTxt,
  }) : _payloads = payloads,
       _fetchNovelDetail = fetchNovelDetail,
       _fetchSeriesTxt = fetchSeriesTxt,
       _readLocalNovelTxt = readLocalNovelTxt;

  static final _seriesUrlPattern = RegExp(r'^/novel/series_(\d+)\.txt$');
  static final _localUrlPattern = RegExp(r'^/novel/local_(\d+)\.txt$');
  static final _singleUrlPattern = RegExp(r'^/novel/(\d+)\.txt$');

  final NovelTxtPayloadStore _payloads;
  final Future<NovelEntity> Function(int novelId)? _fetchNovelDetail;
  final Future<String> Function(int seriesId)? _fetchSeriesTxt;
  final Future<String?> Function(int localId)? _readLocalNovelTxt;

  Future<String> _rebuildPayload(DownloadRequest request) async {
    final path = request.url.path;
    final seriesMatch = _seriesUrlPattern.firstMatch(path);
    if (seriesMatch != null) {
      final fetcher = _fetchSeriesTxt;
      if (fetcher == null) {
        throw const FormatException('novel series TXT payload unavailable');
      }
      return fetcher(int.parse(seriesMatch.group(1)!));
    }
    final localMatch = _localUrlPattern.firstMatch(path);
    if (localMatch != null) {
      final reader = _readLocalNovelTxt;
      if (reader == null) {
        throw const FormatException('local novel TXT payload unavailable');
      }
      final content = await reader(int.parse(localMatch.group(1)!));
      if (content == null) {
        throw const FormatException('local novel file is unavailable');
      }
      return content;
    }
    final singleMatch = _singleUrlPattern.firstMatch(path);
    if (singleMatch != null) {
      final fetcher = _fetchNovelDetail;
      if (fetcher == null) {
        throw const FormatException('novel TXT payload unavailable');
      }
      final novel = await fetcher(int.parse(singleMatch.group(1)!));
      if (!novel.contentAvailable) {
        throw const FormatException('novel content is unavailable');
      }
      return formatPixivNovelTxt(novel);
    }
    throw FormatException('unsupported novel TXT URL: $path');
  }

  Future<void> execute({
    required DownloadRequest request,
    required DownloadSubmissionSnapshot snapshot,
    required DownloadSink sink,
    required DownloadCancelToken cancelToken,
    required void Function() checkOwner,
    required DownloadTargetProgressCallback onProgress,
  }) async {
    checkOwner();
    if (cancelToken.isCancelled) throw const DownloadCancelledException();

    final text = _payloads.get(request.url) ?? await _rebuildPayload(request);

    checkOwner();
    if (cancelToken.isCancelled) throw const DownloadCancelledException();

    final bytes = Uint8List.fromList(utf8.encode(text));
    onProgress(receivedBytes: 0, totalBytes: bytes.length);
    for (var offset = 0; offset < bytes.length; offset += 64 * 1024) {
      if (cancelToken.isCancelled) throw const DownloadCancelledException();
      checkOwner();
      final end = (offset + 64 * 1024).clamp(0, bytes.length);
      await sink.write(Uint8List.sublistView(bytes, offset, end));
      onProgress(receivedBytes: end, totalBytes: bytes.length);
    }
    if (cancelToken.isCancelled) throw const DownloadCancelledException();
    checkOwner();
  }
}
