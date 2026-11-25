import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../novel/novel_entity.dart';
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

final novelTxtPayloadStoreProvider = Provider<NovelTxtPayloadStore>(
  (ref) => NovelTxtPayloadStore(),
);

/// Executes [DownloadTarget.novelTxt] jobs inside [DownloadManager], writing
/// UTF-8 `.txt` bytes in chunks to the owned [DownloadSink].
class NovelTxtDownloadExecutor {
  NovelTxtDownloadExecutor({
    required NovelTxtPayloadStore payloads,
    Future<NovelEntity> Function(int novelId)? fetchNovelDetail,
  }) : _payloads = payloads,
       _fetchNovelDetail = fetchNovelDetail;

  final NovelTxtPayloadStore _payloads;
  final Future<NovelEntity> Function(int novelId)? _fetchNovelDetail;

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

    var text = _payloads.get(request.url);
    if (text == null) {
      final fetcher = _fetchNovelDetail;
      if (fetcher == null) {
        throw const FormatException('novel TXT payload unavailable');
      }
      final novel = await fetcher(request.illustId);
      if (!novel.contentAvailable) {
        throw const FormatException('novel content is unavailable');
      }
      text = formatPixivNovelTxt(novel);
    }

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
