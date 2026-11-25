import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format/app_format.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../core/auth/account_store.dart';
import '../../core/errors/no_retry.dart';
import '../../core/localnovel/local_novel_decoder.dart';
import '../../core/localnovel/local_novel_repository.dart';
import '../../core/localnovel/local_novel_store.dart';
import '../../core/localnovel/read_offset_anchor.dart';
import '../../core/network/data_worker.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/reader_settings.dart';
import '../../core/user/user_entity.dart';
import '../../l10n/context.dart';
import 'novel_layout.dart';
import 'novel_reader.dart';
import 'novel_reader_stage.dart';
import '../../app/theme/func_semantic_tokens.dart';

/// Pre-indexed local novel built once off the UI isolate so widget rebuilds
/// allocate zero paragraph lists and progress load/save stay O(log N) / O(1).
class _LoadedLocalNovel {
  const _LoadedLocalNovel({
    required this.novel,
    required this.entity,
    required this.lineStarts,
    required this.textLength,
  });

  final LocalNovel novel;
  final NovelEntity entity;
  final Int32List lineStarts;
  final int textLength;
}

_LoadedLocalNovel _buildLoadedLocalNovel((LocalNovel, String) input) {
  final (novel, text) = input;
  final lineStarts = buildLocalNovelLineStarts(text);
  final bool hasPixivMarkers =
      novel.isPixivCached ||
      text.contains('[chapter:') ||
      text.contains('[newpage]');
  final NovelMarkupDocument? parsed = hasPixivMarkers
      ? NovelContentMapper.parse(text, images: false)
      : null;
  final List<NovelParagraph> paragraphs =
      parsed?.paragraphs ??
      List<NovelParagraph>.generate(lineStarts.length, (i) {
        final start = lineStarts[i];
        final end = i + 1 < lineStarts.length
            ? lineStarts[i + 1] - 1
            : text.length;
        return NovelParagraph(id: 'p$i', text: text.substring(start, end));
      }, growable: false);
  final entity = NovelEntity(
    // Negative id keeps the synthetic entity disjoint from real Pixiv
    // novel ids anywhere an id leaks into an observer.
    id: -novel.id,
    title: novel.title,
    caption: '',
    user: UserEntity(id: 0, name: novel.author ?? '', account: 'local'),
    tags: const [],
    seriesId: novel.pixivSeriesId,
    seriesTitle: novel.pixivSeriesTitle,
    textLength: text.length,
    contentVersion: 'local:${novel.id}:${text.length}',
    paragraphs: paragraphs,
    markup: parsed,
  );
  return _LoadedLocalNovel(
    novel: novel,
    entity: entity,
    lineStarts: lineStarts,
    textLength: text.length,
  );
}

/// Loaded local novel: the index row plus memoized entity & line-start table.
final _localNovelContentProvider = FutureProvider.autoDispose
    .family<_LoadedLocalNovel, int>((ref, localId) async {
      final repository = ref.watch(localNovelRepositoryProvider);
      final worker = ref.watch(dataWorkerProvider);
      final novel = await repository.get(localId);
      if (novel == null) {
        throw StateError('local novel $localId not found');
      }
      final text = await File(novel.path).readAsString();
      return worker.run(_buildLoadedLocalNovel, (
        novel,
        text,
      ), label: 'local_novel.index');
    }, retry: noRetry);

/// Local TXT reader — feeds the imported text into the shared
/// [NovelReaderStage] as a synthetic [NovelEntity] and persists a
/// character-offset reading cursor in `local_novels.read_offset`.
class LocalNovelReaderPage extends ConsumerWidget {
  const LocalNovelReaderPage({super.key, required this.localId});

  final int localId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_localNovelContentProvider(localId));
    return Scaffold(
      body: async.when(
        loading: () => const NovelStatusScaffold(child: NovelPageSkeleton()),
        error: (error, _) => NovelStatusScaffold(
          child: FeedError(
            title: context.l10n.localNovelsLoadFailed,
            error: error,
            retryLabel: context.l10n.retry,
            onRetry: () => ref.invalidate(_localNovelContentProvider(localId)),
          ),
        ),
        data: (loaded) => _buildReader(context, loaded),
      ),
    );
  }

  Widget _buildReader(BuildContext context, _LoadedLocalNovel loaded) {
    return NovelReaderStage(
      spec: NovelReaderStageSpec(
        novel: loaded.entity,
        infoTooltip: context.l10n.localNovelFileInfo,
        infoSheet: (_) => _LocalNovelInfoSheet(novel: loaded.novel),
        progress: _LocalProgressBinding(
          ProviderScope.containerOf(context, listen: false),
          loaded: loaded,
        ),
      ),
    );
  }
}

/// File-info sheet content — the stage owns presentation; this owns the
/// fields a local TXT file can describe. `path` is deliberately omitted:
/// it is a technical detail the user cannot act on (D9).
class _LocalNovelInfoSheet extends StatelessWidget {
  const _LocalNovelInfoSheet({required this.novel});

  final LocalNovel novel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final desktop = useWideOverlay(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          FuncSpacing.xl,
          desktop ? FuncSpacing.xl : 0,
          FuncSpacing.xl,
          FuncSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(novel.title, style: Theme.of(context).textTheme.titleLarge),
            // No author row when the import recorded none — local TXT
            // imports never carry one today, so the row is conditional.
            if (novel.author != null) ...[
              const SizedBox(height: FuncSpacing.sm),
              Text(novel.author!),
            ],
            const SizedBox(height: FuncSpacing.sm),
            Text(l10n.localNovelsChars(novel.charCount)),
            const SizedBox(height: FuncSpacing.xs),
            Text(l10n.localNovelFileEncoding(_encodingLabel(novel.encoding))),
            const SizedBox(height: FuncSpacing.xs),
            Text(
              l10n.localNovelFileImportedAt(
                AppFormat.date(context, novel.importedAt, withTime: true),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _encodingLabel(LocalNovelEncoding? encoding) =>
      switch (encoding) {
        LocalNovelEncoding.utf8 => 'UTF-8',
        LocalNovelEncoding.utf16 => 'UTF-16',
        LocalNovelEncoding.gbk => 'GBK',
        // Decoding fell back to lossy UTF-8 — say so instead of letting
        // the label pretend the file was clean.
        LocalNovelEncoding.utf8Lossy => 'UTF-8 (lossy)',
        // Rows imported before the column existed have no value; the
        // decoder defaults to UTF-8, which is also what the file contains.
        null => 'UTF-8',
      };
}

/// `read_offset` persistence behind the stage: `load` maps the stored
/// character offset back to a paragraph anchor, `save` converts the
/// user-committed anchor into a character offset. Both directions treat
/// the `\n` separator as one character so write → read is a stable
/// round trip.
class _LocalProgressBinding implements ReaderProgressBinding {
  const _LocalProgressBinding(this._container, {required this.loaded});

  final ProviderContainer _container;
  final _LoadedLocalNovel loaded;

  String? get _accountId => _container.read(
    accountStoreProvider.select((a) => a.value?.usableCurrent?.id),
  );

  @override
  Future<NovelAnchor?> load() async {
    final localOffset = loaded.novel.readOffset;
    final pixivNovelId = loaded.novel.pixivNovelId;
    final accountId = _accountId;
    NovelAnchor? onlineAnchor;
    int? onlineOffset;
    if (pixivNovelId != null && accountId != null) {
      final saved = await _container
          .read(novelProgressStoreProvider)
          .read(accountId, pixivNovelId);
      if (saved != null) {
        onlineAnchor = NovelAnchor(
          paragraphId: saved.paragraphId,
          offset: saved.offset,
        );
        onlineOffset = localNovelReadOffsetForAnchor(
          paragraphId: saved.paragraphId,
          offset: saved.offset,
          lineStarts: loaded.lineStarts,
          textLength: loaded.textLength,
        );
      }
    }
    if (onlineAnchor != null &&
        (localOffset == null || (onlineOffset ?? 0) > localOffset)) {
      return onlineAnchor;
    }
    final restored = novelAnchorForReadOffsetWithStarts(
      localOffset,
      loaded.lineStarts,
      loaded.textLength,
    );
    if (restored == null) return onlineAnchor;
    return NovelAnchor(
      paragraphId: restored.paragraphId,
      offset: restored.offset,
    );
  }

  @override
  Future<void> save(NovelAnchor anchor) async {
    final offset = localNovelReadOffsetForAnchor(
      paragraphId: anchor.paragraphId,
      offset: anchor.offset,
      lineStarts: loaded.lineStarts,
      textLength: loaded.textLength,
    );
    await _container
        .read(localNovelStoreProvider.notifier)
        .updateReadOffset(loaded.novel.id, offset);
    final pixivNovelId = loaded.novel.pixivNovelId;
    final accountId = _accountId;
    if (pixivNovelId != null && accountId != null) {
      await _container
          .read(novelProgressStoreProvider)
          .write(
            accountId,
            pixivNovelId,
            paragraphId: anchor.paragraphId,
            offset: anchor.offset,
          );
    }
  }
}
