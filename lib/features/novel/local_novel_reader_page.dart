import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/feed/feed_states.dart';
import '../../core/localnovel/local_novel_repository.dart';
import '../../core/localnovel/read_offset_anchor.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/user/user_entity.dart';
import 'novel_layout.dart';
import 'novel_reader.dart';
import '../../l10n/context.dart';

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
/// [NovelReader]/layout engine as a synthetic [NovelEntity] and persists a
/// character-offset reading cursor in `local_novels.read_offset`.
class LocalNovelReaderPage extends ConsumerWidget {
  const LocalNovelReaderPage({super.key, required this.localId});

  final int localId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_localNovelContentProvider(localId));
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.localNovelsTitle)),
      body: async.when(
        loading: () => const FeedLoading(),
        error: (error, _) => FeedError(
          title: context.l10n.localNovelsLoadFailed,
          error: error,
          retryLabel: context.l10n.retry,
          onRetry: () => ref.invalidate(_localNovelContentProvider(localId)),
        ),
        data: (loaded) =>
            _LocalNovelReaderBody(novel: loaded.$1, text: loaded.$2),
      ),
    );
  }
}

class _LocalNovelReaderBody extends ConsumerWidget {
  const _LocalNovelReaderBody({required this.novel, required this.text});

  final LocalNovel novel;
  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entity = _entityFor(novel, text);
    // Restore the persisted read cursor: the stored character offset maps
    // back to the paragraph anchor the reader consumes on first layout.
    final restored = novelAnchorForReadOffset(novel.readOffset, text);
    return Column(
      children: [
        ListTile(
          title: Text(
            novel.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(context.l10n.localNovelsChars(novel.charCount)),
          dense: true,
        ),
        Expanded(
          child: NovelReader(
            novel: entity,
            initialAnchor: restored == null
                ? null
                : NovelAnchor(
                    paragraphId: restored.paragraphId,
                    offset: restored.offset,
                  ),
            onAnchorChanged: (anchor) => _persistCursor(ref, entity, anchor),
          ),
        ),
      ],
    );
  }

  /// Converts the anchor (paragraph id + intra-paragraph offset) into a
  /// character offset in the stored text and records it.
  void _persistCursor(WidgetRef ref, NovelEntity entity, NovelAnchor anchor) {
    var offset = anchor.offset;
    for (final paragraph in entity.paragraphs) {
      if (paragraph.id == anchor.paragraphId) break;
      offset += paragraph.text.length + 1;
    }
    unawaited(
      ref.read(localNovelRepositoryProvider).updateReadOffset(novel.id, offset),
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
