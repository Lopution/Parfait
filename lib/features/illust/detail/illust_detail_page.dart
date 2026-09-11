import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart' show DownloadEvent;
import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/history/history_models.dart';
import '../../../core/history/history_repository.dart';
import '../../../core/history/history_snapshot.dart';
import '../../../core/history/history_visibility.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../app/widgets/bookmark_switch_button.dart';
import '../../../core/illust/illust_detail_controller.dart';
import '../../../core/illust/illust_download_controller.dart';
import '../../../app/motion/hero_transition.dart';
import '../../../app/widgets/feed/feed_states.dart';
import 'related_illusts_section.dart';
import 'widgets/info_block.dart';
import 'widgets/page_image.dart';
import 'ugoira_viewer.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../l10n/context.dart';

class IllustDetailPage extends ConsumerStatefulWidget {
  const IllustDetailPage({
    super.key,
    required this.illustId,
    this.initialEntity,
    this.heroScope = 'feed',
    this.heroImageUrl,
  });

  final int illustId;
  final IllustEntity? initialEntity;
  final String heroScope;
  final String? heroImageUrl;

  @override
  ConsumerState<IllustDetailPage> createState() => _IllustDetailPageState();
}

class _IllustDetailPageState extends ConsumerState<IllustDetailPage> {
  bool _downloadMode = false;
  bool _blockMode = false;
  StreamSubscription<DownloadEvent>? _downloadEvents;

  @override
  void initState() {
    super.initState();
    // Start fetching related works as soon as the detail page opens (the
    // official client does too). The section further down is a lazy sliver:
    // without this prefetch the request only began once the user scrolled
    // to the bottom, which read as an endless spinner.
    unawaited(
      ref
          .read(relatedIllustControllerProvider(widget.illustId).future)
          .then((_) {}, onError: (Object _) {}),
    );
  }

  @override
  void dispose() {
    _downloadEvents?.cancel();
    super.dispose();
  }

  /// Download badge states derive from live manager tasks; without this
  /// subscription the Provider-backed snapshot would never notify the UI.
  void _ensureDownloadListener() {
    _downloadEvents ??= ref.read(downloadManagerProvider).events.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _toggleDownloadMode() => setState(() => _downloadMode = !_downloadMode);

  @override
  Widget build(BuildContext context) {
    _ensureDownloadListener();
    final async = ref.watch(illustDetailControllerProvider(widget.illustId));
    return Scaffold(
      appBar: _buildAppBar(context, ref, async),
      body: async.when(
        // U5 (R7): AsyncNotifier.build() returns a Future, so the first
        // frame is ALWAYS AsyncLoading — a spinner here would hide the
        // store snapshot the feed already placed in IllustStore, and the
        // Hero destination would not exist on the first frame. Render the
        // snapshot immediately; the controller's IllustDetailLoading state
        // stays as the no-snapshot first-load signal.
        loading: () {
          final snapshot = _snapshotEntity();
          if (snapshot != null) {
            return _buildContent(context, ref, snapshot);
          }
          return const FeedLoading();
        },
        error: (Object error, StackTrace _) => FeedError(
          title: context.l10n.illustDetailLoadFailed,
          error: error,
          retryLabel: context.l10n.retry,
          onRetry: () => ref
              .read(illustDetailControllerProvider(widget.illustId).notifier)
              .reload(),
        ),
        data: (state) {
          // Snapshot-first (R1): the shared store renders stale data behind
          // any in-flight refresh; the controller state drives the terminal
          // surfaces (the loading branch above reads the store directly).
          return switch (state) {
            IllustDetailRestricted(:final entity) => FeedEmpty(
              icon: Icons.visibility_off_outlined,
              title: context.l10n.illustDetailRestricted(entity.id),
            ),
            IllustDetailNotFound() => FeedEmpty(
              icon: Icons.search_off,
              title: context.l10n.illustDetailNotFound,
            ),
            IllustDetailReady(:final entity) => _buildContent(
              context,
              ref,
              entity,
              detailReady: true,
            ),
            IllustDetailError(:final error, :final snapshot) =>
              _errorOrSnapshot(context, ref, error, snapshot),
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
        entity?.title ?? context.l10n.illustDetailTitle,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      actions: [
        if (_downloadMode && entity != null)
          IconButton(
            tooltip: context.l10n.downloadAll,
            onPressed: () {
              try {
                download.downloadAll(entity);
              } catch (error) {
                // Any submission failure must be visible on device: the
                // manager/ownership/channel errors that are not
                // FormatException otherwise vanish with no UI feedback.
                showAppSnackBar(
                  context,
                  context.l10n.downloadSubmissionFailed(error.toString()),
                );
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
      IllustDetailError(:final snapshot) => snapshot ?? _snapshotEntity(),
      _ => _snapshotEntity(),
    };
  }

  IllustEntity? _snapshotEntity() =>
      ref.read(illustStoreProvider).get(widget.illustId) ??
      widget.initialEntity;

  Widget _errorOrSnapshot(
    BuildContext context,
    WidgetRef ref,
    Object error,
    IllustEntity? snapshot,
  ) {
    final entity = snapshot ?? _snapshotEntity();
    if (entity != null) return _buildContent(context, ref, entity);
    return FeedError(
      title: context.l10n.illustDetailLoadFailed,
      error: error,
      retryLabel: context.l10n.retry,
      onRetry: () => ref
          .read(illustDetailControllerProvider(widget.illustId).notifier)
          .reload(),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    IllustEntity entity, {
    bool detailReady = false,
  }) {
    // 三档质量之详情档: the detail-page hero follows the user's detail
    // quality once the detail payload is merged; before that it shows the
    // feed-provided hero URL so the Hero flight stays on one cache key.
    final detailQuality = ref.watch(detailQualityProvider);
    String? detailUrlFor(int index) =>
        detailReady ? entity.detailUrlAt(index, detailQuality) : null;
    final content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_downloadMode) _toggleDownloadMode();
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          // Related works paginate as the user reaches the bottom of the
          // page (official client behaviour). loadMore is internally
          // guarded against re-entry / exhausted state.
          final metrics = notification.metrics;
          if (metrics.maxScrollExtent > 0 &&
              metrics.pixels >= metrics.maxScrollExtent - 500) {
            // loadMore asserts an AsyncData state (it calls requireValue),
            // so only hand the scroll event over once the first page
            // actually loaded.
            final relatedState = ref.read(
              relatedIllustControllerProvider(widget.illustId),
            );
            if (relatedState.hasValue) {
              ref
                  .read(
                    relatedIllustControllerProvider(widget.illustId).notifier,
                  )
                  .loadMore();
            }
          }
          return false;
        },
        child: CustomScrollView(
          slivers: [
            if (entity.isUgoira)
              SliverToBoxAdapter(
                child: UgoiraViewer(
                  illustId: entity.id,
                  // Keep the first frame on the exact feed URL during the
                  // initial Hero hand-off, then follow the same detail
                  // quality selection as still and multi-page works. The
                  // shared PixivImage inside UgoiraViewer keeps this URL
                  // change gapless while a decoded frame (if any) remains
                  // above it.
                  previewUrl:
                      detailUrlFor(0) ??
                      widget.heroImageUrl ??
                      entity.imageUrls.large,
                  width: entity.width,
                  height: entity.height,
                  downloadMode: _downloadMode,
                  onLongPress: _toggleDownloadMode,
                  heroTag: illustHeroTag(widget.heroScope, entity.id),
                  flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                ),
              )
            else if (entity.pageCount == 1)
              SliverToBoxAdapter(
                child: DetailPageImage(
                  key: ValueKey<Object?>('illust-page-${entity.id}-0'),
                  entity: entity,
                  index: 0,
                  heroTag: illustHeroTag(widget.heroScope, entity.id),
                  heroScope: widget.heroScope,
                  heroImageUrl: widget.heroImageUrl,
                  detailUrl: detailUrlFor(0),
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
                    child: DetailPageImage(
                      key: ValueKey<Object?>('illust-page-${entity.id}-$index'),
                      entity: entity,
                      index: index,
                      heroTag: index == 0
                          ? illustHeroTag(widget.heroScope, entity.id)
                          : '${illustHeroTag(widget.heroScope, entity.id)}-$index',
                      heroScope: widget.heroScope,
                      heroImageUrl: index == 0 ? widget.heroImageUrl : null,
                      detailUrl: detailUrlFor(index),
                      downloadMode: _downloadMode,
                      onLongPress: _toggleDownloadMode,
                      placeholderOnly: !detailReady && index > 0,
                    ),
                  ),
                  // All pages appear immediately: before the detail payload the
                  // non-first pages render as neutral placeholders (uniform
                  // ratio), and the real images/proportions replace them when
                  // the detail API payload is merged.
                  childCount: entity.pageCount,
                ),
              ),
            SliverToBoxAdapter(
              child: InfoBlock(
                entity: entity,
                blockMode: _blockMode,
                onToggleBlockMode: () =>
                    setState(() => _blockMode = !_blockMode),
              ),
            ),
            // Official client behaviour: "関連作品" below the caption/tags,
            // paginated as the user scrolls to the bottom of the page.
            RelatedIllustsSlivers(illustId: widget.illustId),
          ],
        ),
      ),
    );
    final accountId = ref.watch(historyAccountIdProvider);
    if (accountId == null) return content;
    final pixivEnabled = ref.watch(pixivHistoryEnabledProvider);
    return HistoryVisibility(
      accountId: accountId,
      contentType: HistoryContentType.illust,
      contentId: entity.id,
      snapshot: snapshotFromIllust(entity),
      localHistoryEnabled: ref.watch(localHistoryEnabledProvider),
      pixivHistoryEnabled: pixivEnabled,
      repository: ref.watch(historyRepositoryProvider),
      remote: pixivEnabled ? ref.watch(pixivHistoryRemoteProvider) : null,
      isAccountCurrent: () => ref.read(historyAccountIdProvider) == accountId,
      child: content,
    );
  }
}
