import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/routes.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../core/localnovel/local_novel_decoder.dart';
import '../../core/localnovel/local_novel_repository.dart';
import '../../core/localnovel/local_novel_store.dart';
import '../../l10n/context.dart';

/// The imported-TXT library: list rows (title/size/import time), an import
/// action, and delete — reading itself is wired by the local reader route.
class LocalNovelsPage extends ConsumerWidget {
  const LocalNovelsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(localNovelStoreProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.localNovelsTitle),
        actions: [
          IconButton(
            tooltip: context.l10n.localNovelsImport,
            onPressed: () => _import(context, ref),
            icon: const Icon(Icons.file_open_outlined),
          ),
        ],
      ),
      body: async.when(
        loading: () => const FeedLoading(),
        error: (error, _) => FeedError(
          title: context.l10n.localNovelsLoadFailed,
          error: error,
          retryLabel: context.l10n.retry,
          onRetry: () => ref.invalidate(localNovelStoreProvider),
        ),
        data: (novels) {
          if (novels.isEmpty) {
            return FeedEmpty(
              icon: Icons.menu_book_outlined,
              title: context.l10n.localNovelsEmpty,
              retryLabel: context.l10n.localNovelsImport,
              onRefresh: () => _import(context, ref),
            );
          }
          return PullToRefresh(
            onRefresh: () async => ref.invalidate(localNovelStoreProvider),
            child: ListView.builder(
              itemCount: novels.length,
              itemBuilder: (context, index) =>
                  _LocalNovelTile(novel: novels[index]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    try {
      final novel = await ref
          .read(localNovelStoreProvider.notifier)
          .importPicked();
      if (!context.mounted || novel == null) return;
      showAppSnackBar(
        context,
        novel.encoding == LocalNovelEncoding.utf8Lossy
            ? context.l10n.localNovelsImportedLossy
            : context.l10n.localNovelsImported(novel.title),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        '${context.l10n.localNovelsImportFailed}: $error',
      );
    }
  }
}

class _LocalNovelTile extends ConsumerWidget {
  const _LocalNovelTile({required this.novel});

  final LocalNovel novel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.menu_book_outlined),
      title: Text(novel.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          context.l10n.localNovelsChars(novel.charCount),
          '${novel.importedAt.year}-'
              '${novel.importedAt.month.toString().padLeft(2, '0')}-'
              '${novel.importedAt.day.toString().padLeft(2, '0')}',
        ].join(' · '),
      ),
      onTap: () => openLocalNovelReader(context, novel.id),
      trailing: IconButton(
        tooltip: context.l10n.localNovelsDelete,
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _confirmDelete(context, ref),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.localNovelsDelete),
        content: Text(context.l10n.localNovelsDeleteConfirm(novel.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.l10n.localNovelsDelete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(localNovelStoreProvider.notifier).delete(novel);
    }
  }
}
