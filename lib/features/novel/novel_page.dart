import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pixiv_image.dart';
import '../../app/replica_page_route.dart';
import '../../core/i18n/replica_strings.dart';
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
import '../profile/user_page.dart';
import 'novel_reader.dart';
import 'novel_layout.dart';

/// Opens the JSON Novel detail route. Save/share are intentionally absent:
/// this task does not claim those operations without a real API contract.
void showNovelPage(BuildContext context, int novelId) {
  if (novelId <= 0) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(_novelText(context, 'novelNotFound'))),
    );
    return;
  }
  Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(builder: (_) => NovelPage(novelId: novelId)),
  );
}

final novelDetailProvider = FutureProvider.autoDispose.family<NovelEntity, int>(
  (ref, novelId) async {
    final token = CancelToken();
    ref.onDispose(token.cancel);
    final repository = ref.read(novelRepositoryProvider);
    final entity = await repository.fetchDetail(novelId, cancelToken: token);
    ref.read(novelStoreProvider.notifier).mergeAll([entity]);
    return entity;
  },
);

final novelSeriesProvider = FutureProvider.autoDispose
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
    final async = ref.watch(novelDetailProvider(novelId));
    final title = async.value?.title ?? _novelText(context, 'profileNovel');
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: async.when(
        loading: () => _NovelStatus(
          icon: Icons.menu_book_outlined,
          title: _novelText(context, 'novelLoading'),
        ),
        error: (error, _) => _NovelError(
          error: error,
          onRetry: () => ref.invalidate(novelDetailProvider(novelId)),
        ),
        data: (novel) {
          if (novel.isRestricted) {
            return _NovelStatus(
              icon: Icons.lock_outline,
              title: _novelText(context, 'novelRestricted'),
            );
          }
          if (!novel.contentAvailable) {
            return _NovelStatus(
              icon: Icons.text_snippet_outlined,
              title: _novelText(context, 'novelContentUnavailable'),
            );
          }
          return _NovelDetailBody(novel: novel);
        },
      ),
    );
  }
}

class NovelCard extends StatelessWidget {
  const NovelCard({super.key, required this.entity});

  final NovelEntity entity;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        onTap: () => showNovelPage(context, entity.id),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _NovelCover(entity: entity),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entity.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      entity.user.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (entity.seriesTitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        entity.seriesTitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '${entity.textLength} ${_novelText(context, 'novelWords')}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _NovelCover extends StatelessWidget {
  const _NovelCover({required this.entity});

  final NovelEntity entity;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 68,
        height: 88,
        child: entity.coverImageUrl == null
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.menu_book_outlined),
              )
            : PixivImage(url: entity.coverImageUrl!, fit: BoxFit.cover),
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
              onTap: () => showUserPage(context, novel.user.id),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipOval(
                    child: SizedBox(
                      width: 32,
                      height: 32,
                      child: novel.user.profileImageUrl == null
                          ? ColoredBox(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              child: const Icon(Icons.person_outline, size: 18),
                            )
                          : PixivImage(
                              url: novel.user.profileImageUrl!,
                              fit: BoxFit.cover,
                            ),
                    ),
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
    final async = ref.watch(novelSeriesProvider(seriesId));
    return async.when(
      loading: () => const LinearProgressIndicator(minHeight: 1),
      error: (error, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(
          '${_novelText(context, 'novelSeriesUnavailable')}: $error',
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
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              IconButton(
                tooltip: _novelText(context, 'novelPrevious'),
                onPressed: previous?.viewable == true
                    ? () => showNovelPage(context, previous!.id)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  series.title ?? _novelText(context, 'novelSeries'),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: _novelText(context, 'novelNext'),
                onPressed: next?.viewable == true
                    ? () => showNovelPage(context, next!.id)
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

class _NovelStatus extends StatelessWidget {
  const _NovelStatus({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48),
          const SizedBox(height: 12),
          Text(title),
        ],
      ),
    );
  }
}

class _NovelError extends StatelessWidget {
  const _NovelError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final isNotFound =
        error is ApiHttpError && (error as ApiHttpError).statusCode == 404;
    final title = isNotFound
        ? _novelText(context, 'novelNotFound')
        : _novelText(context, 'novelLoadFailed');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text(title),
            const SizedBox(height: 8),
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onRetry,
              child: Text(_novelText(context, 'novelRetry')),
            ),
          ],
        ),
      ),
    );
  }
}

String _novelText(BuildContext context, String key) => ReplicaStrings.fromTag(
  Localizations.localeOf(context).toLanguageTag(),
  key,
);
