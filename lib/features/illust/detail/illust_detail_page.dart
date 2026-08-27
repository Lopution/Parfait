import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/pixiv_image.dart';
import '../../../app/replica_page_route.dart';
import 'dart:async';

import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart' show DownloadEvent;
import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/settings/blocked_tags.dart';
import '../../bookmark/bookmark_switch_button.dart';
import '../../search/tag_search_page.dart';
import '../viewer/image_viewer_page.dart';
import 'illust_detail_controller.dart';
import 'illust_download_controller.dart';

/// Detail page replicating beta56 illust.dart: images with download mode,
/// author block, meta row, caption, tag chips (R2/R4/R5).
class IllustDetailPage extends ConsumerStatefulWidget {
  const IllustDetailPage({super.key, required this.illustId});

  final int illustId;

  @override
  ConsumerState<IllustDetailPage> createState() => _IllustDetailPageState();
}

class _IllustDetailPageState extends ConsumerState<IllustDetailPage> {
  bool _downloadMode = false;
  bool _blockMode = false;
  bool _showCaption = false;
  StreamSubscription<DownloadEvent>? _downloadEvents;

  @override
  void dispose() {
    _downloadEvents?.cancel();
    super.dispose();
  }

  /// Download badge states derive from live manager tasks; without this
  /// subscription the Provider-backed snapshot would never notify the UI.
  void _ensureDownloadListener() {
    _downloadEvents ??= ref
        .read(downloadManagerProvider)
        .events
        .listen((_) => setState(() {}));
  }

  void _toggleDownloadMode() =>
      setState(() => _downloadMode = !_downloadMode);

  @override
  Widget build(BuildContext context) {
    _ensureDownloadListener();
    final async = ref.watch(illustDetailControllerProvider(widget.illustId));
    return Scaffold(
      appBar: _buildAppBar(context, ref, async),
      body: async.when(
        loading: () => const Center(child: CupertinoActivityIndicator()),
        error: (Object error, StackTrace _) => _ErrorView(
          error: error,
          onRetry: () => ref
              .read(illustDetailControllerProvider(widget.illustId).notifier)
              .reload(),
        ),
        data: (state) {
          // Snapshot-first (R1): the shared store renders stale data behind
          // any in-flight refresh; the controller state drives the terminal
          // surfaces.
          final snapshot = ref.watch(illustStoreProvider).get(widget.illustId);
          return switch (state) {
            IllustDetailRestricted(:final entity) => _RestrictedView(entity),
            IllustDetailNotFound() => const _NotFoundView(),
            IllustDetailReady(:final entity) => _buildContent(
              context,
              ref,
              entity,
            ),
            IllustDetailError(:final error, :final snapshot) =>
              snapshot != null
                  ? _buildContent(context, ref, snapshot)
                  : _ErrorView(
                      error: error,
                      onRetry: () => ref
                          .read(
                            illustDetailControllerProvider(
                              widget.illustId,
                            ).notifier,
                          )
                          .reload(),
                    ),
            IllustDetailLoading() =>
              snapshot != null
                  ? _buildContent(context, ref, snapshot)
                  : const Center(child: CupertinoActivityIndicator()),
          };
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<IllustDetailState> async,
  ) {
    final entity = _entityOf(async);
    final download = ref.watch(illustDownloadControllerProvider);
    return AppBar(
      title: Text(
        entity?.title ?? '作品详情',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      actions: [
        if (_downloadMode && entity != null)
          IconButton(
            tooltip: 'Download All',
            onPressed: () {
              try {
                download.downloadAll(entity);
              } on FormatException catch (error) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(error.message)));
              }
            },
            icon: const Icon(Icons.file_download_outlined),
          ),
        // Beta56 keeps the bookmark heart in the app bar actions at all
        // times (isButton: false variant, tap toggles / long-press sheet
        // only while unbookmarked).
        if (entity != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: BookmarkSwitchButton(
                illustId: entity.id,
                title: entity.title,
                isButton: false,
              ),
            ),
          ),
      ],
    );
  }

  IllustEntity? _entityOf(AsyncValue<IllustDetailState> async) {
    final state = async.value;
    return switch (state) {
      IllustDetailReady(:final entity) => entity,
      IllustDetailRestricted(:final entity) => entity,
      IllustDetailError(:final snapshot) => snapshot,
      _ => null,
    };
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    IllustEntity entity,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_downloadMode) _toggleDownloadMode();
      },
      child: CustomScrollView(
        slivers: [
          if (entity.isUgoira)
            SliverToBoxAdapter(
              child: _UgoiraCover(
                entity: entity,
                onLongPress: _toggleDownloadMode,
              ),
            )
          else if (entity.pageCount == 1)
            SliverToBoxAdapter(
              child: _PageImage(
                entity: entity,
                index: 0,
                heroTag: 'IllustHero-${entity.id}',
                downloadMode: _downloadMode,
                onLongPress: _toggleDownloadMode,
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => Padding(
                  padding: EdgeInsets.only(
                    bottom: index == entity.pageCount - 1 ? 0 : 10,
                  ),
                  child: _PageImage(
                    entity: entity,
                    index: index,
                    heroTag: index == 0
                        ? 'IllustHero-${entity.id}'
                        : 'IllustHero-${entity.id}-$index',
                    downloadMode: _downloadMode,
                    onLongPress: _toggleDownloadMode,
                  ),
                ),
                childCount: entity.pageCount,
              ),
            ),
          SliverToBoxAdapter(
            child: _InfoBlock(
              entity: entity,
              showCaption: _showCaption,
              blockMode: _blockMode,
              onToggleCaption: () =>
                  setState(() => _showCaption = !_showCaption),
              onToggleBlockMode: () => setState(() => _blockMode = !_blockMode),
            ),
          ),
        ],
      ),
    );
  }
}

class _PageImage extends ConsumerWidget {
  const _PageImage({
    required this.entity,
    required this.index,
    required this.heroTag,
    required this.downloadMode,
    required this.onLongPress,
  });

  final IllustEntity entity;
  final int index;
  final String heroTag;
  final bool downloadMode;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final download = ref.watch(illustDownloadControllerProvider);
    final state = download.stateFor(entity.id, index);
    final previewUrl = entity.pageCount > 1
        ? (index < entity.metaPages.length
              ? entity.metaPages[index].medium
              : entity.imageUrls.medium)
        : entity.imageUrls.large;
    final image = GestureDetector(
      onTap: () => _openViewer(context),
      onLongPress: onLongPress,
      child: AspectRatio(
        aspectRatio: entity.width > 0 && entity.height > 0
            ? entity.width / entity.height
            : 1.0,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PixivImage(
              url: previewUrl,
              fit: BoxFit.cover,
              width: double.infinity,
              filterColor: downloadMode ? Colors.white24 : null,
              filterBlendMode: downloadMode ? BlendMode.srcOver : null,
            ),
            if (downloadMode)
              Positioned(
                top: 20,
                right: 20,
                child: _DownloadBadge(
                  state: state,
                  onTap: () {
                    try {
                      download.download(entity, index);
                    } on FormatException catch (error) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(error.message)));
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
    return Hero(tag: heroTag, child: image);
  }

  void _openViewer(BuildContext context) {
    final urls = <String>[
      for (var i = 0; i < entity.pageCount; i++)
        entity.originalUrlAt(i) ?? entity.viewerUrls().first,
    ];
    Navigator.of(context).push(
      ReplicaPageRoute<void>(
        builder: (_) => ImageViewerPage(urls: urls, initialPage: index),
      ),
    );
  }
}

class _DownloadBadge extends StatelessWidget {
  const _DownloadBadge({required this.state, required this.onTap});

  final IllustPageSaveState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final child = switch (state) {
      IllustPageSaveState.none => const Icon(
        Icons.file_download_outlined,
        size: 30,
      ),
      IllustPageSaveState.downloading => const SizedBox(
        width: 30,
        height: 30,
        child: CircularProgressIndicator(),
      ),
      IllustPageSaveState.error => const Icon(
        Icons.file_download_outlined,
        size: 30,
      ),
      IllustPageSaveState.exist => Icon(
        Icons.check,
        color: theme.colorScheme.primary,
        size: 30,
      ),
    };
    return GestureDetector(
      onTap: state == IllustPageSaveState.downloading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(30),
        ),
        child: child,
      ),
    );
  }
}

class _UgoiraCover extends StatelessWidget {
  const _UgoiraCover({required this.entity, required this.onLongPress});

  final IllustEntity entity;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    // R7: badge + cover only; the typed route to the player lands with the
    // ugoira task. No fake playback affordance.
    return GestureDetector(
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PixivImage(
            url: entity.imageUrls.large,
            fit: BoxFit.fitWidth,
            width: double.infinity,
          ),
          Positioned(
            left: 7,
            bottom: 7,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                color: const Color(0x99343838),
              ),
              child: const Icon(
                Icons.gif_box_outlined,
                color: Colors.white,
                size: 30,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBlock extends ConsumerWidget {
  const _InfoBlock({
    required this.entity,
    required this.showCaption,
    required this.blockMode,
    required this.onToggleCaption,
    required this.onToggleBlockMode,
  });

  final IllustEntity entity;
  final bool showCaption;
  final bool blockMode;
  final VoidCallback onToggleCaption;
  final VoidCallback onToggleBlockMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final blockedTags = ref.watch(blockedTagsProvider);
    final blockedController = ref.read(blockedTagsProvider.notifier);
    final createDate = DateTime.tryParse(entity.createDate ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundImage: entity.user.profileImageUrl == null
                    ? null
                    : CachedNetworkImageProvider(
                        entity.user.profileImageUrl!,
                        headers: PixivImage.headers,
                      ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entity.user.name,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      entity.user.account,
                      style: textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Text(
                  createDate == null
                      ? '投稿日期未知'
                      : '投稿日期：${createDate.year}/${createDate.month}/${createDate.day}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.remove_red_eye_outlined, size: 12),
              const SizedBox(width: 5),
              Text('${entity.totalView}'),
              const SizedBox(width: 5),
              const Icon(Icons.favorite_border, size: 12),
              const SizedBox(width: 5),
              Text('${entity.totalBookmarks}'),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Text('尺寸：${entity.width}x${entity.height}'),
              const SizedBox(width: 5),
              Text('ID: ${entity.id}'),
            ],
          ),
          if (entity.caption.isNotEmpty) ...[
            const SizedBox(height: 5),
            GestureDetector(
              onTap: onToggleCaption,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  const SizedBox(width: 15),
                  Text(
                    '简介',
                    style: TextStyle(
                      color: showCaption ? theme.colorScheme.primary : null,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Icon(
                    showCaption
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 12,
                    color: showCaption ? theme.colorScheme.primary : null,
                  ),
                ],
              ),
            ),
            if (showCaption)
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 20),
                child: Text(entity.caption),
              ),
          ],
          const SizedBox(height: 20),
          Wrap(
            children: [
              for (final tag in entity.tags)
                _TagChip(
                  tag: tag,
                  blockMode: blockMode,
                  blocked: blockedTags.contains(tag.name),
                  onTap: () {
                    if (blockMode) {
                      blockedController.toggle(tag.name);
                    } else {
                      showTagSearch(context, tag.name);
                    }
                  },
                  onLongPress: onToggleBlockMode,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.tag,
    required this.blockMode,
    required this.blocked,
    required this.onTap,
    required this.onLongPress,
  });

  final IllustTag tag;
  final bool blockMode;
  final bool blocked;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: theme.colorScheme.surface,
              ),
              child: Text(
                '#${tag.name}${tag.translatedName != null ? ' ${tag.translatedName}' : ''}',
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
          if (blockMode)
            Positioned(
              top: 0,
              right: 0,
              child: Icon(
                Icons.block,
                size: 15,
                color: blocked ? theme.colorScheme.primary : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _RestrictedView extends StatelessWidget {
  const _RestrictedView(this.entity);

  final IllustEntity entity;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.visibility_off_outlined, size: 48),
          const SizedBox(height: 12),
          Text('该作品已被删除或受限（ID: ${entity.id}）'),
        ],
      ),
    );
  }
}

class _NotFoundView extends StatelessWidget {
  const _NotFoundView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 48),
          SizedBox(height: 12),
          Text('作品不存在或已被删除'),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            const Text('作品加载失败'),
            const SizedBox(height: 8),
            Text('$error', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
