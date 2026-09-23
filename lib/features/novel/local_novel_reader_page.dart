import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/feed/feed_states.dart';
import '../../core/localnovel/local_novel_repository.dart';
import '../../core/localnovel/read_offset_anchor.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/user/user_entity.dart';
import '../../l10n/context.dart';
import 'novel_layout.dart';
import 'novel_reader_stage.dart';

/// Loaded local novel: the index row plus the decoded text on disk.
final _localNovelContentProvider = FutureProvider.autoDispose
    .family<(LocalNovel, String), int>((ref, localId) async {
      final repository = ref.watch(localNovelRepositoryProvider);
      final novel = await repository.get(localId);
      if (novel == null) {
        throw StateError('local novel $localId not found');
      }
      return (novel, await File(novel.path).readAsString());
    });

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
        loading: () =>
            const NovelStatusScaffold(child: FeedLoading()),
        error: (error, _) => NovelStatusScaffold(
          child: FeedError(
            title: context.l10n.localNovelsLoadFailed,
            error: error,
            retryLabel: context.l10n.retry,
            onRetry: () =>
                ref.invalidate(_localNovelContentProvider(localId)),
          ),
        ),
        data: (loaded) =>
            _buildReader(context, ref, novel: loaded.$1, text: loaded.$2),
      ),
    );
  }

  Widget _buildReader(
    BuildContext context,
    WidgetRef ref, {
    required LocalNovel novel,
    required String text,
  }) {
    final entity = _entityFor(novel, text);
    return NovelReaderStage(
      spec: NovelReaderStageSpec(
        novel: entity,
        infoTooltip: context.l10n.localNovelsTitle,
        infoSheet: (_) => _LocalNovelInfoSheet(novel: novel),
        progress: _LocalProgressBinding(
          ProviderScope.containerOf(context, listen: false),
          novel: novel,
          text: text,
          entity: entity,
        ),
      ),
    );
  }

  static NovelEntity _entityFor(LocalNovel novel, String text) {
    final lines = text.split('\n');
    return NovelEntity(
      // Negative id keeps the synthetic entity disjoint from real Pixiv
      // novel ids anywhere an id leaks into an observer.
      id: -novel.id,
      title: novel.title,
      caption: '',
      user: UserEntity(id: 0, name: novel.author ?? '', account: 'local'),
      tags: const [],
      textLength: text.length,
      contentVersion: 'local:${novel.id}:${text.length}',
      paragraphs: [
        for (var i = 0; i < lines.length; i++)
          NovelParagraph(id: 'p$i', text: lines[i]),
      ],
    );
  }
}

/// File-info sheet content — the stage owns presentation; this owns the
/// fields a local TXT file can describe.
class _LocalNovelInfoSheet extends StatelessWidget {
  const _LocalNovelInfoSheet({required this.novel});

  final LocalNovel novel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(novel.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(context.l10n.localNovelsChars(novel.charCount)),
        ],
      ),
    );
  }
}

/// `read_offset` persistence behind the stage: `load` maps the stored
/// character offset back to a paragraph anchor, `save` converts the
/// user-committed anchor into a character offset. Both directions treat
/// the `\n` separator as one character so write → read is a stable
/// round trip.
class _LocalProgressBinding implements ReaderProgressBinding {
  const _LocalProgressBinding(
    this._container, {
    required this.novel,
    required this.text,
    required this.entity,
  });

  final ProviderContainer _container;
  final LocalNovel novel;
  final String text;
  final NovelEntity entity;

  @override
  Future<NovelAnchor?> load() async {
    final restored = novelAnchorForReadOffset(novel.readOffset, text);
    if (restored == null) return null;
    return NovelAnchor(
      paragraphId: restored.paragraphId,
      offset: restored.offset,
    );
  }

  @override
  Future<void> save(NovelAnchor anchor) {
    var offset = anchor.offset;
    for (final paragraph in entity.paragraphs) {
      if (paragraph.id == anchor.paragraphId) break;
      offset += paragraph.text.length + 1;
    }
    return _container
        .read(localNovelRepositoryProvider)
        .updateReadOffset(novel.id, offset);
  }
}
