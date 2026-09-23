import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart' show DownloadEvent;
import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/history/history_models.dart';
import '../../../core/history/history_repository.dart';
import '../../../core/history/history_snapshot.dart';
import '../../../core/history/history_visibility.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../core/share/share_service.dart';
import '../../../app/widgets/bookmark_switch_button.dart';
import '../../../core/illust/illust_detail_controller.dart';
import '../../../core/illust/illust_download_controller.dart';
import '../../../app/haptics/app_haptics.dart';
import '../../../app/motion/motion_tokens.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/motion/hero_transition.dart';
import '../../../app/widgets/feed/feed_states.dart';
import 'related_illusts_section.dart';
import 'widgets/detail_image_pager.dart';
import 'widgets/illust_series_section.dart';
import 'widgets/info_block.dart';
import 'widgets/page_image.dart';
import 'ugoira_viewer.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../l10n/context.dart';
import '../../../app/layout/app_breakpoints.dart';
import '../../../app/layout/two_pane.dart';
import '../../../app/widgets/smooth_wheel_scroll.dart';

class IllustDetailPage extends ConsumerStatefulWidget {
  const IllustDetailPage({
    super.key,
    required this.illustId,
    this.initialEntity,
    this.heroScope = 'feed',
    this.heroImageUrl,
    this.heroImageDecodeWidth,
  });

  final int illustId;
  final IllustEntity? initialEntity;
  final String heroScope;
  final String? heroImageUrl;

  /// The feed card's decode width for [heroImageUrl] — decoding the hero
  /// phase at this width reuses the feed's decoded cache entry, so the
  /// landing frame does not re-decode the same file at screen width.
  final int? heroImageDecodeWidth;

  @override
  ConsumerState<IllustDetailPage> createState() => _IllustDetailPageState();
}

class _IllustDetailPageState extends ConsumerState<IllustDetailPage> {
  /// Page indexes selected in the explicit download-selection mode;
  /// `null` means the mode is off. A non-null empty set means the mode is
  /// on with nothing selected yet — "Done" stays disabled until n > 0.
  Set<int>? _selectedPages;

  /// Narrow-layout compact header: the topmost image page currently in
  /// view feeds the `n/共N页` counter (VisibilityDetector per page,
  /// 200ms cadence — the counter does not need frame-exact updates).
  final Set<int> _visiblePages = <int>{};
  final GlobalKey _infoAnchorKey = GlobalKey();

  int get _firstVisiblePage =>
      _visiblePages.isEmpty ? 0 : _visiblePages.reduce(math.min);

  void _onPageVisibility(int index, VisibilityInfo info) {
    final visible = info.visibleFraction > 0;
    final before = _firstVisiblePage;
    if (visible) {
      _visiblePages.add(index);
    } else {
      _visiblePages.remove(index);
    }
    if (_firstVisiblePage != before && mounted) setState(() {});
  }

  /// The 「信息」 button scrolls the meta column's InfoBlock into view.
  /// ensureVisible uses the target's own context (risks R9 — we never
  /// touch SmoothWheelScroll's controller).
  void _scrollToInfo() {
    final ctx = _infoAnchorKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx, duration: MotionTokens.medium);
  }

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

  bool get _downloadMode => _selectedPages != null;

  /// Entering the mode is a management-mode transition → confirm haptic.
  void _enterDownloadMode() {
    if (_downloadMode) return;
    AppHaptics.confirm();
    setState(() => _selectedPages = <int>{});
  }

  /// Any exit path (cancel button, blank tap, system back) is a light
  /// confirmation. In-flight download tasks are owned by DownloadManager
  /// and are never touched here — the mode is only a selection layer.
  void _exitDownloadMode() {
    if (!_downloadMode) return;
    AppHaptics.select();
    setState(() => _selectedPages = null);
  }

  void _togglePageSelected(int index) {
    final selected = _selectedPages;
    if (selected == null) return;
    AppHaptics.select();
    setState(() {
      if (!selected.remove(index)) selected.add(index);
    });
  }

  void _selectAllPages(IllustEntity entity) {
    if (_selectedPages == null) return;
    AppHaptics.select();
    setState(() {
      _selectedPages = {for (var i = 0; i < entity.pageCount; i++) i};
    });
  }

  /// "Done" submits every selected page through the download controller
  /// (dedupe/retry-safe). Success exits the mode; failure keeps the mode
  /// and the selection so the user can retry the remainder.
  Future<void> _submitSelection(IllustEntity entity) async {
    final selected = _selectedPages;
    if (selected == null || selected.isEmpty) return;
    final download = ref.read(illustDownloadControllerProvider);
    try {
      for (final index in selected.toList()..sort()) {
        await download.download(entity, index);
      }
    } catch (error) {
      if (!mounted) return;
      AppHaptics.error();
      showAppSnackBar(
        context,
        context.l10n.downloadSubmissionFailed(error.toString()),
      );
      return;
    }
    if (!mounted) return;
    AppHaptics.success();
    showAppSnackBar(context, context.l10n.downloadQueuedMessage);
    setState(() => _selectedPages = null);
  }

  @override
  Widget build(BuildContext context) {
    _ensureDownloadListener();
    final async = ref.watch(illustDetailControllerProvider(widget.illustId));
    final entity = _entityOf(async);
    return PopScope(
      // While the selection mode is on, system back exits the mode instead
      // of leaving the page (the AppBar back button routes through maybePop
      // and lands on the same branch). In-flight downloads are untouched —
      // the mode is only a UI selection layer.
      canPop: !_downloadMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitDownloadMode();
      },
      child: Scaffold(
        appBar: _buildAppBar(context, ref, async),
        bottomNavigationBar: AnimatedSwitcher(
          duration: MotionTokens.fast,
          child: _downloadMode && entity != null && !entity.isUgoira
              ? _DownloadSelectionBar(
                  selected: _selectedPages?.length ?? 0,
                  total: entity.pageCount,
                  onSelectAll: () => _selectAllPages(entity),
                  onDone: (_selectedPages?.isEmpty ?? true)
                      ? null
                      : () => unawaited(_submitSelection(entity)),
                  onCancel: _exitDownloadMode,
                )
              : const SizedBox.shrink(),
        ),
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
      // The work title lives in the body (Shaft's hero_title / official
      // client layout): a single-line AppBar slot ellipsises anything
      // beyond a handful of characters, so the bar keeps a generic label
      // and the real title wraps freely in InfoBlock.
      title: Text(context.l10n.illustDetailTitle),
      actions: [
        if (entity != null)
          IconButton(
            tooltip: context.l10n.cardActionShare,
            onPressed: () => _share(context, ref, entity),
            icon: const Icon(Icons.share_outlined),
          ),
        // "Download all" is the always-visible plain download entry — it
        // is no longer gated behind the selection mode.
        if (entity != null)
          IconButton(
            tooltip: context.l10n.downloadAll,
            onPressed: () async {
              try {
                await download.downloadAll(entity);
              } catch (error) {
                // Any submission failure must be visible on device: the
                // manager/ownership/channel errors that are not
                // FormatException otherwise vanish with no UI feedback.
                if (!context.mounted) return;
                AppHaptics.error();
                showAppSnackBar(
                  context,
                  context.l10n.downloadSubmissionFailed(error.toString()),
                );
                return;
              }
              if (!context.mounted) return;
              AppHaptics.success();
              showAppSnackBar(context, context.l10n.downloadQueuedMessage);
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

  Future<void> _share(
    BuildContext context,
    WidgetRef ref,
    IllustEntity entity,
  ) async {
    final outcome = await ref
        .read(shareServiceProvider)
        .share(
          SharePayload.illust(
            id: entity.id,
            title: entity.title,
            author: entity.user.name,
          ),
          sharePositionOrigin: shareOriginOf(context),
        );
    if (outcome == ShareOutcome.copiedToClipboard && context.mounted) {
      showAppSnackBar(context, context.l10n.linkCopied);
    }
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

    // The media column and the metadata column are the same slivers in both
    // layouts; only their arrangement differs (single scroll vs two panes).
    final imageSlivers = <Widget>[
      if (entity.isUgoira)
        SliverToBoxAdapter(
          child: VisibilityDetector(
            key: ValueKey('illust-visibility-${entity.id}-0'),
            onVisibilityChanged: (info) => _onPageVisibility(0, info),
            child: UgoiraViewer(
              illustId: entity.id,
              // Same contract as DetailPageImage: the viewer keeps the
              // feed card's URL for the opening Hero flight and only
              // upgrades to the detail quality once the route settles —
              // without the guard a cached detail payload would swap
              // the cover mid-flight onto an undecoded entry (the
              // grey-shuttle regression).
              // Ugoira has no page selection: long-press does not enter the
              // download mode and the GIF export action stays always visible.
              previewUrl: entity.imageUrls.large,
              detailUrl: detailUrlFor(0),
              heroImageUrl: widget.heroImageUrl,
              heroTier: widget.heroImageUrl == null
                  ? null
                  : entity.imageTierOf(widget.heroImageUrl!),
              width: entity.width,
              height: entity.height,
              heroTag: illustHeroTag(widget.heroScope, entity.id),
              flightShuttleBuilder: illustHeroFlightShuttleBuilder,
              heroDecodeWidth: widget.heroImageDecodeWidth,
              heroPopUrl: widget.heroImageUrl,
              heroPopDecodeWidth: widget.heroImageDecodeWidth,
              tier: entity.imageTierOf(
                detailUrlFor(0) ?? entity.imageUrls.large,
              ),
            ),
          ),
        )
      else if (entity.pageCount == 1)
        SliverToBoxAdapter(
          child: VisibilityDetector(
            key: ValueKey('illust-visibility-${entity.id}-0'),
            onVisibilityChanged: (info) => _onPageVisibility(0, info),
            child: DetailPageImage(
              key: ValueKey<Object?>('illust-page-${entity.id}-0'),
              entity: entity,
              index: 0,
              heroTag: illustHeroTag(widget.heroScope, entity.id),
              heroScope: widget.heroScope,
              heroImageUrl: widget.heroImageUrl,
              heroImageDecodeWidth: widget.heroImageDecodeWidth,
              detailUrl: detailUrlFor(0),
              downloadMode: _downloadMode,
              selected: _selectedPages?.contains(0) ?? false,
              onToggleSelect: () => _togglePageSelected(0),
              onLongPress: _enterDownloadMode,
            ),
          ),
        )
      else
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => Padding(
              padding: EdgeInsets.only(
                bottom: index == entity.pageCount - 1 ? 0 : 10,
              ),
              child: VisibilityDetector(
                key: ValueKey('illust-visibility-${entity.id}-$index'),
                onVisibilityChanged: (info) => _onPageVisibility(index, info),
                child: DetailPageImage(
                  key: ValueKey<Object?>('illust-page-${entity.id}-$index'),
                  entity: entity,
                  index: index,
                  heroTag: index == 0
                      ? illustHeroTag(widget.heroScope, entity.id)
                      : '${illustHeroTag(widget.heroScope, entity.id)}-$index',
                  heroScope: widget.heroScope,
                  heroImageUrl: index == 0 ? widget.heroImageUrl : null,
                  heroImageDecodeWidth: index == 0
                      ? widget.heroImageDecodeWidth
                      : null,
                  detailUrl: detailUrlFor(index),
                  downloadMode: _downloadMode,
                  selected: _selectedPages?.contains(index) ?? false,
                  onToggleSelect: () => _togglePageSelected(index),
                  onLongPress: _enterDownloadMode,
                  placeholderOnly: !detailReady && index > 0,
                ),
              ),
            ),
            // All pages appear immediately: before the detail payload the
            // non-first pages render as neutral placeholders (uniform
            // ratio), and the real images/proportions replace them when
            // the detail API payload is merged.
            childCount: entity.pageCount,
          ),
        ),
    ];
    final metaSlivers = <Widget>[
      // Official client behaviour: when the work belongs to an
      // illust series, the series card sits between the image pages
      // and the info block (name, 第 N 话, prev/next navigation).
      IllustSeriesSection(illustId: widget.illustId),
      SliverToBoxAdapter(
        // The compact header's 「信息」 button scrolls to this anchor
        // (ensureVisible by context — no controller takeover, risks R9).
        child: Container(
          key: _infoAnchorKey,
          child: InfoBlock(
            entity: entity,
            blockMode: _blockMode,
            onToggleBlockMode: () => setState(() => _blockMode = !_blockMode),
          ),
        ),
      ),
      // Official client behaviour: "関連作品" below the caption/tags,
      // paginated as the user scrolls to the bottom of the page.
      RelatedIllustsSlivers(illustId: widget.illustId),
    ];

    // Related works paginate as the user reaches the bottom of the page
    // (official client behaviour). loadMore is internally guarded against
    // re-entry / exhausted state.
    bool onScrollNotification(ScrollNotification notification) {
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
              .read(relatedIllustControllerProvider(widget.illustId).notifier)
              .loadMore();
        }
      }
      return false;
    }

    final metaScroll = NotificationListener<ScrollNotification>(
      onNotification: onScrollNotification,
      child: SmoothWheelScroll(
        builder: (context, controller, physics) => CustomScrollView(
          controller: controller,
          physics: physics,
          slivers: metaSlivers,
        ),
      ),
    );

    final content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_downloadMode) _exitDownloadMode();
      },
      child: AppBreakpoints.useTwoPaneDetail(MediaQuery.sizeOf(context).width)
          ? TwoPane(
              primary: DetailImagePager(
                entity: entity,
                detailUrlFor: detailUrlFor,
                downloadMode: _downloadMode,
                selectedPages: _selectedPages ?? const <int>{},
                onToggleSelect: _togglePageSelected,
                onLongPress: _enterDownloadMode,
                heroTag: illustHeroTag(widget.heroScope, entity.id),
                heroScope: widget.heroScope,
                heroImageUrl: widget.heroImageUrl,
                heroImageDecodeWidth: widget.heroImageDecodeWidth,
              ),
              // The meta column owns the window's right edge, so its
              // scrollbar lands where the main scrollbar belongs.
              secondary: Scrollbar(child: metaScroll),
            )
          : Column(
              children: [
                // Narrow-only compact header: persistent title/author/
                // page-count context + an info jump that scrolls to
                // InfoBlock (design §2.2 — the two-pane branch already
                // carries the same info in its right column).
                _CompactDetailHeader(
                  entity: entity,
                  visiblePage: _firstVisiblePage,
                  onInfo: _scrollToInfo,
                ),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: onScrollNotification,
                    child: SmoothWheelScroll(
                      builder: (context, controller, physics) =>
                          CustomScrollView(
                            controller: controller,
                            physics: physics,
                            slivers: [...imageSlivers, ...metaSlivers],
                          ),
                    ),
                  ),
                ),
              ],
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

/// Narrow-layout (<1200) persistent header under the AppBar: the detail
/// body keeps title/author/page-context visible while the user scrolls
/// through pages, and the 「信息」 button jumps straight to InfoBlock.
/// Not rendered in the two-pane layout (the meta column carries the same
/// information) or in degraded states (this only builds inside
/// _buildContent, which requires a non-null entity).
class _CompactDetailHeader extends StatelessWidget {
  const _CompactDetailHeader({
    required this.entity,
    required this.visiblePage,
    required this.onInfo,
  });

  final IllustEntity entity;
  final int visiblePage;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FuncSpacing.lg,
          vertical: FuncSpacing.xs,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entity.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    entity.user.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: FuncSpacing.sm),
            Text(
              l10n.viewerPageLabel(visiblePage + 1, entity.pageCount),
              style: theme.textTheme.bodySmall,
            ),
            IconButton(
              tooltip: l10n.illustInfoJump,
              onPressed: onInfo,
              icon: const Icon(Icons.info_outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom chrome of the explicit download-selection mode (R2): mode
/// title + selected/total count + select-all + done + cancel. "Done" is
/// semantically disabled while nothing is selected.
class _DownloadSelectionBar extends StatelessWidget {
  const _DownloadSelectionBar({
    required this.selected,
    required this.total,
    required this.onSelectAll,
    required this.onDone,
    required this.onCancel,
  });

  final int selected;
  final int total;
  final VoidCallback onSelectAll;
  final VoidCallback? onDone;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FuncSpacing.lg,
            vertical: FuncSpacing.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.downloadSelectPages, style: theme.textTheme.labelLarge),
              const SizedBox(height: FuncSpacing.xs),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.downloadSelectedCount(selected, total),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: onSelectAll,
                    child: Text(l10n.selectAll),
                  ),
                  const SizedBox(width: FuncSpacing.xs),
                  FilledButton(onPressed: onDone, child: Text(l10n.done)),
                  TextButton(onPressed: onCancel, child: Text(l10n.cancel)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
