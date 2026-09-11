import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/person_avatar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/navigation/routes.dart';
import '../../core/history/history_models.dart';
import '../../core/history/history_repository.dart';
import '../../core/history/history_snapshot.dart';
import '../../core/history/history_visibility.dart';
import '../../core/network/api_error.dart';
import '../../core/network/pixiv_http_client.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_repository.dart';
import '../../core/novel/novel_store.dart';
import '../../core/settings/settings_controller.dart';
import 'novel_reader.dart';
import 'novel_layout.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/context.dart';

/// Opens the JSON Novel detail route. Save/share are intentionally absent:
/// this task does not claim those operations without a real API contract.
void _showNovelPage(BuildContext context, int novelId) {
  if (novelId <= 0) {
    showAppSnackBar(context, context.l10n.novelNotFound);
    return;
  }
  openNovel(context, novelId);
}

final _novelDetailProvider = FutureProvider.autoDispose
    .family<NovelEntity, int>((ref, novelId) async {
      final token = CancelToken();
      ref.onDispose(token.cancel);
      final repository = ref.read(novelRepositoryProvider);
      final entity = await repository.fetchDetail(novelId, cancelToken: token);
      ref.read(novelStoreProvider.notifier).mergeAll([entity]);
      return entity;
    });

final _novelSeriesProvider = FutureProvider.autoDispose
    .family<NovelSeriesPage, int>((ref, seriesId) async {
      final token = CancelToken();
      ref.onDispose(token.cancel);
      return ref
          .read(novelRepositoryProvider)
          .fetchSeries(seriesId, cancelToken: token);
    });

class NovelPage extends ConsumerWidget {
  const NovelPage({super.key, required this.novelId});

  final int novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_novelDetailProvider(novelId));
    final title = async.value?.title ?? context.l10n.profileNovel;
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: async.when(
        loading: () => FeedEmpty(
          icon: Icons.menu_book_outlined,
          title: context.l10n.novelLoading,
        ),
        error: (error, _) {
          final isNotFound = error is ApiHttpError && error.statusCode == 404;
          return FeedError(
            title: isNotFound
                ? context.l10n.novelNotFound
                : context.l10n.novelLoadFailed,
            error: error,
            retryLabel: context.l10n.novelRetry,
            onRetry: () => ref.invalidate(_novelDetailProvider(novelId)),
          );
        },
        data: (novel) {
          if (novel.isRestricted) {
            return FeedEmpty(
              icon: Icons.lock_outline,
              title: context.l10n.novelRestricted,
            );
          }
          if (!novel.contentAvailable) {
            return FeedEmpty(
              icon: Icons.text_snippet_outlined,
              title: context.l10n.novelContentUnavailable,
            );
          }
          return _NovelDetailBody(novel: novel);
        },
      ),
    );
  }
}

class _NovelDetailBody extends ConsumerStatefulWidget {
  const _NovelDetailBody({required this.novel});

  final NovelEntity novel;

  @override
  ConsumerState<_NovelDetailBody> createState() => _NovelDetailBodyState();
}

class _NovelDetailBodyState extends ConsumerState<_NovelDetailBody> {
  NovelAnchor? _anchor;

  @override
  Widget build(BuildContext context) {
    final novel = widget.novel;
    final content = Column(
      children: [
        _NovelMetadata(novel: novel),
        if (novel.seriesId != null)
          _NovelSeriesBar(seriesId: novel.seriesId!, novelId: novel.id),
        Expanded(
          child: NovelReader(
            novel: novel,
            onAnchorChanged: (anchor) {
              if (_anchor == anchor) return;
              setState(() => _anchor = anchor);
            },
          ),
        ),
      ],
    );
    final accountId = ref.watch(historyAccountIdProvider);
    if (accountId == null) return content;
    final pixivEnabled = ref.watch(pixivHistoryEnabledProvider);
    return HistoryVisibility(
      accountId: accountId,
      contentType: HistoryContentType.novel,
      contentId: novel.id,
      snapshot: snapshotFromNovel(
        novel,
        anchorParagraphId: _anchor?.paragraphId,
        anchorOffset: _anchor?.offset,
      ),
      localHistoryEnabled: ref.watch(localHistoryEnabledProvider),
      pixivHistoryEnabled: pixivEnabled,
      repository: ref.watch(historyRepositoryProvider),
      remote: pixivEnabled ? ref.watch(pixivHistoryRemoteProvider) : null,
      isAccountCurrent: () => ref.read(historyAccountIdProvider) == accountId,
      child: content,
    );
  }
}

class _NovelMetadata extends StatelessWidget {
  const _NovelMetadata({required this.novel});

  final NovelEntity novel;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 180),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(novel.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 7),
            InkWell(
              onTap: () => openUser(context, novel.user.id),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PersonAvatar(
                    imageUrl: novel.user.profileImageUrl,
                    radius: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(novel.user.name),
                ],
              ),
            ),
            if (novel.caption.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(novel.caption, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
            if (novel.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final tag in novel.tags)
                    Chip(
                      label: Text(tag.translatedName ?? tag.name),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NovelSeriesBar extends ConsumerWidget {
  const _NovelSeriesBar({required this.seriesId, required this.novelId});

  final int seriesId;
  final int novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_novelSeriesProvider(seriesId));
    return async.when(
      loading: () => const LinearProgressIndicator(minHeight: 1),
      error: (error, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(
          '${context.l10n.novelSeriesUnavailable}: $error',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      data: (series) {
        final index = series.entries.indexWhere((entry) => entry.id == novelId);
        if (index < 0) return const SizedBox.shrink();
        final previous = index > 0 ? series.entries[index - 1] : null;
        final next = index + 1 < series.entries.length
            ? series.entries[index + 1]
            : null;
        if (previous == null && next == null) return const SizedBox.shrink();
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Row(
            children: [
              IconButton(
                tooltip: context.l10n.novelPrevious,
                onPressed: previous?.viewable == true
                    ? () => _showNovelPage(context, previous!.id)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  series.title ?? context.l10n.novelSeries,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: context.l10n.novelNext,
                onPressed: next?.viewable == true
                    ? () => _showNovelPage(context, next!.id)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        );
      },
    );
  }
}
