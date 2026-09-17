import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../entity/illust_entity.dart';
import 'download_recovery.dart';
import 'download_sink.dart';

/// Writes the work caption next to the downloaded image as `<stem>.txt`
/// (implement.md step 5). Shaft parity: the info-header layout and the
/// `<br>` → newline cleanup mirror `IllustCaptionExporter.buildContent`.
///
/// Export is triggered at submit time by the coordinator; dedupe is per
/// (account, illust, destination) so repeated submissions write once.
class CaptionExporter {
  CaptionExporter({
    required RawDownloadSinkFactory sinkFactory,
    required SharedPreferencesAsync preferences,
  }) : _sinkFactory = sinkFactory,
       _preferences = preferences;

  final RawDownloadSinkFactory _sinkFactory;
  final SharedPreferencesAsync _preferences;

  /// Only illust/manga pages participate — ugoira and other targets carry
  /// no downloadable image caption pairing.
  static const _supportedTypes = {IllustType.illust, IllustType.manga};

  static String _dedupeKey(
    DownloadSubmissionSnapshot submission,
    int illustId,
  ) =>
      'caption_exported:${submission.accountId}:$illustId:'
      '${submission.destination.identity}';

  /// Exports [illust]'s caption as `<pageZeroStem>.txt` into the same
  /// destination the submission used. No-op when already exported for this
  /// (account, illust, destination). Write failures abort the pending
  /// output and propagate to the caller — never silent.
  Future<void> export({
    required IllustEntity illust,
    required DownloadSubmissionSnapshot submission,
    required String pageZeroName,
  }) async {
    if (!_supportedTypes.contains(illust.type)) return;
    if (!submission.isOwned) return;
    final key = _dedupeKey(submission, illust.id);
    if (await _preferences.getBool(key) ?? false) return;

    final dot = pageZeroName.lastIndexOf('.');
    final stem = dot < 0 ? pageZeroName : pageZeroName.substring(0, dot);
    final sink = await _sinkFactory.beginRaw(
      displayName: '$stem.txt',
      mimeType: 'text/plain',
      destination: submission.destination,
      owner: DownloadOutputOwner(
        ownerId: 'caption:${illust.id}',
        jobId: submission.jobId,
        accountId: submission.accountId,
      ),
    );
    try {
      await sink.write(utf8.encode(_buildContent(illust)));
      await sink.finalize();
    } catch (_) {
      await sink.abort();
      rethrow;
    }
    // Mark exported only after the write is durable — a failed attempt must
    // retry on the next submission instead of being recorded as done.
    await _preferences.setBool(key, true);
  }

  /// Shaft `buildContent` layout: 标题/作者/作者ID/作品ID/链接/标签/简介.
  static String _buildContent(IllustEntity illust) {
    final buffer = StringBuffer()
      ..write('标题：${illust.title}\n\n')
      ..write('作者：${illust.user.name}\n\n')
      ..write('作者ID：${illust.user.id}\n\n')
      ..write('作品ID：${illust.id}\n\n')
      ..write('作品链接：https://www.pixiv.net/artworks/${illust.id}\n\n');
    final tags = [
      for (final tag in illust.tags)
        if (tag.name.isNotEmpty) tag.name,
    ];
    if (tags.isNotEmpty) {
      buffer.write('标签：${tags.join(', ')}\n\n');
    }
    buffer
      ..write('简介：\n')
      ..write(_captionText(illust.caption))
      ..write('\n');
    return buffer.toString();
  }

  /// Pixiv captions carry `<br>` markup; the sidecar is plain text (Shaft
  /// `replaceBrWithNewLine`).
  static String _captionText(String caption) =>
      caption.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
}
