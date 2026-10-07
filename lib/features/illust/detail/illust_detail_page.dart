import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../app/widgets/app_top_bar.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart'
    show DownloadEvent, DownloadGroupSubmission;
import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/history/history_models.dart';
import '../../../core/history/history_repository.dart';
import '../../../core/history/history_snapshot.dart';
import '../../../core/history/history_visibility.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../core/share/share_service.dart';
import '../../../app/widgets/app_menu_button.dart';
import '../../../app/widgets/selection_app_bar.dart';
import '../../../core/illust/illust_detail_controller.dart';
import '../../../core/illust/illust_download_controller.dart';
import '../../../app/haptics/app_haptics.dart';
import '../../../app/motion/motion_tokens.dart';
import '../../../app/motion/scroll_hide.dart';
import '../../../app/motion/state_fade.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/motion/hero_transition.dart';
import '../../../app/widgets/feed/feed_states.dart';
import 'author_works_section.dart';
import 'comments_preview_section.dart';
import 'related_illusts_section.dart';
import 'widgets/detail_action_bar.dart';
import 'widgets/detail_image_pager.dart';
import 'widgets/illust_detail_skeleton.dart';
import 'widgets/detail_page_counter.dart';
import 'widgets/illust_series_section.dart';
import 'widgets/info_block.dart';
import 'widgets/page_image.dart';
import 'ugoira_viewer.dart';
import '../../../app/navigation/routes.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/errors/error_details.dart';
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

class _IllustDetailPageState extends ConsumerState<IllustDetailPage>
    with TickerProviderStateMixin {
  /// Page indexes selected in the explicit download-selection mode;
  /// `null` means the mode is off. A non-null empty set means the mode is
  /// on with nothing selected yet — "Done" stays disabled until n > 0.
  Set<int>? _selectedPages;

  /// Page-counter overlay data: the topmost image page currently in
  /// view feeds the `n / m` pill (VisibilityDetector per page — the pill
  /// hides for a single page). Empty set
  /// means nothing artwork is on screen (scrolled into the meta tail).
  final Set<int> _visiblePages = <int>{};

  /// The pill's page, kept out of this State: the trackers report on their
  /// own timer, typically while a swipe settles, and a page setState would
  /// rebuild every built page, the info block and the related grid just to
  /// move a counter.
  final ValueNotifier<int?> _topVisiblePage = ValueNotifier<int?>(null);
  final GlobalKey _infoAnchorKey = GlobalKey();

  /// Passed to the narrow layout's [SmoothWheelScroll] `controller:`
  /// parameter so the artwork-info jump can walk the lazily-built page
  /// list until the InfoBlock anchor exists. The component then uses this
  /// as its scroll controller — it only builds an internal one when none
  /// is passed — so we never touch a controller the component owns (R9).
  final ScrollController _narrowScroll = ScrollController();

  /// The floating action bar's presence (1 shown): it slides away while
  /// reading down and returns on the way back up, like the shell's bar.
  late final AnimationController _barVisibility = AnimationController(
    vsync: this,
    value: 1,
  );
  late final CurvedAnimation _barCurve = CurvedAnimation(
    parent: _barVisibility,
    curve: MotionTokens.navBarShowCurve,
    reverseCurve: MotionTokens.navBarHideCurve,
  );
  final _scrollHide = ScrollHideTracker();

  /// TalkBack is exploring: chrome that slides away cannot be found, so
  /// the bar stays.
  bool _touchExploration = false;

  /// How drawn the top bar is over the narrow layout's first image: 0
  /// while the image is under it, 1 once the image has scrolled away
  /// (see [AppTopBar.immersion]).
  final _immersion = ValueNotifier<double>(0);

  /// Scroll offset where the top bar starts drawing; set by each build
  /// from the first image's height.
  double _immersionStart = 0;

  /// Status bar plus toolbar over the narrow layout's artwork; 0 in the
  /// two-pane layout, whose pages sit below an opaque bar.
  double _topChromeExtent = 0;

  /// The top bar's arrival. The Hero image flying in from a card is drawn
  /// over the see-through bar, so the bar waits for the route to land and
  /// then fades in (see [AppTopBar.entrance]); without a card it is there
  /// at once.
  late final AnimationController _topBarEntrance = AnimationController(
    vsync: this,
    value: widget.heroImageUrl == null ? 1 : 0,
  );
  Animation<double>? _routeAnimation;

  @override
  void initState() {
    super.initState();
    _narrowScroll.addListener(_updateImmersion);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _barVisibility
      ..duration = MotionTokens.resolve(context, MotionTokens.navBarShow)
      ..reverseDuration = MotionTokens.resolve(
        context,
        MotionTokens.navBarHide,
      );
    _touchExploration = MediaQuery.accessibleNavigationOf(context);
    if (_touchExploration) _barVisibility.value = 1;
    _topBarEntrance.duration = MotionTokens.resolve(context, MotionTokens.fast);
    final route = ModalRoute.of(context)?.animation;
    if (!identical(route, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_onRouteStatus);
      _routeAnimation = route?..addStatusListener(_onRouteStatus);
      // Read after the first frame: before the push starts, the route's
      // proxy still reports a completed placeholder.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _onRouteStatus(_routeAnimation?.status ?? AnimationStatus.completed);
        }
      });
    }
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status.isCompleted) _topBarEntrance.forward();
  }

  /// The bar draws over the last toolbar height before the first image
  /// leaves the screen top, so it is solid by the time content would
  /// scroll under it.
  void _updateImmersion() {
    if (!_narrowScroll.hasClients) return;
    final drawn = (_narrowScroll.offset - _immersionStart) / kToolbarHeight;
    _immersion.value = drawn.clamp(0.0, 1.0).toDouble();
  }

  /// Folds an expanded set back to page 1. A reader already past page 1
  /// lands where the shorter list now ends — page 1's bottom under the top
  /// bar, the expand button and info right below — instead of wherever
  /// the list happens to clamp.
  void _collapsePages(double firstPageEnd) {
    if (_narrowScroll.hasClients && _narrowScroll.offset > firstPageEnd) {
      _narrowScroll.jumpTo(firstPageEnd);
    }
    setState(() => _pagesExpanded = false);
  }

  bool _onBarScroll(ScrollNotification notification) {
    if (_touchExploration) return false;
    final slop = MediaQuery.maybeGestureSettingsOf(context)?.touchSlop ?? 8.0;
    final hide = _scrollHide.update(notification, slop: slop);
    if (hide != null) slideChrome(context, _barVisibility, hidden: hide);
    return false;
  }

  void _onPageVisibility(int index, VisibilityInfo info) {
    // A detector torn down with the page still reports once more.
    if (!mounted) return;
    // The narrow layout runs under the see-through top bar: a page leaving
    // the top whose last strip sits behind the bar is not on screen to the
    // reader, and the count must not hang over the info below it.
    final bounds = info.visibleBounds;
    final behindTopChrome = bounds.top > 0 && bounds.height <= _topChromeExtent;
    if (info.visibleFraction > 0 && !behindTopChrome) {
      _visiblePages.add(index);
    } else {
      _visiblePages.remove(index);
    }
    _topVisiblePage.value = _visiblePages.isEmpty
        ? null
        : _visiblePages.reduce(math.min);
  }

  /// The ⋮ menu's artwork-info item scrolls the InfoBlock into view.
  /// The InfoBlock sliver is built
  /// lazily below the page list, so on long works the narrow scroll first
  /// steps one viewport at a time until the anchor exists — each step's
  /// viewport is contiguous with the previous one, so every section gets
  /// built as we pass. ensureVisible uses the target's own context
  /// (risks R9 — we never touch SmoothWheelScroll's controller).
  Future<void> _scrollToInfo() async {
    while (_infoAnchorKey.currentContext == null && _narrowScroll.hasClients) {
      final position = _narrowScroll.position;
      if (position.pixels >= position.maxScrollExtent) break;
      position.jumpTo(
        math.min(
          position.pixels + position.viewportDimension,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final anchor = _infoAnchorKey.currentContext;
    if (anchor == null || !anchor.mounted) return;
    await Scrollable.ensureVisible(
      anchor,
      duration: MotionTokens.resolve(anchor, MotionTokens.medium),
    );
  }

  bool _blockMode = false;

  /// Whether a multi-image illustration shows every page. Lives with this
  /// page only: a new visit starts collapsed again.
  bool _pagesExpanded = false;
  StreamSubscription<DownloadEvent>? _downloadEvents;

  @override
  void dispose() {
    _downloadEvents?.cancel();
    _narrowScroll.dispose();
    _topVisiblePage.dispose();
    _barCurve.dispose();
    _barVisibility.dispose();
    _immersion.dispose();
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _topBarEntrance.dispose();
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
    // Every page has to be on screen to be picked.
    setState(() {
      _selectedPages = <int>{};
      _pagesExpanded = true;
    });
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
      showErrorSnackBar(
        context,
        action: context.l10n.downloadSubmissionFailed,
        error: error,
      );
      return;
    }
    if (!mounted) return;
    showDownloadSubmittedSnackBar(context);
    setState(() => _selectedPages = null);
  }

  @override
  Widget build(BuildContext context) {
    _ensureDownloadListener();
    final async = ref.watch(illustDetailControllerProvider(widget.illustId));
    final entity = _entityOf(async);
    // The narrow layout opens on the artwork under a see-through bar —
    // the skeleton too, so content arriving never shifts it.
    final immersive =
        !AppBreakpoints.useTwoPaneDetail(MediaQuery.sizeOf(context).width) &&
        (entity == null ? async.isLoading : _rendersContent(async, entity));
    return PopScope(
      // While the selection mode is on, system back exits the mode instead
      // of leaving the page, like the selection bar's close button.
      // In-flight downloads are untouched — the mode is only a UI
      // selection layer.
      canPop: !_downloadMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitDownloadMode();
      },
      child: Scaffold(
        extendBodyBehindAppBar: immersive,
        appBar: _downloadMode && entity != null
            ? _buildSelectionAppBar(context, entity)
            : _buildAppBar(context, async, immersive: immersive),
        body: _fadeStates(
          async.when(
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
              return const IllustDetailSkeleton();
            },
            error: (Object error, StackTrace _) => FeedError(
              title: context.l10n.illustDetailLoadFailed,
              error: error,
              retryLabel: context.l10n.retry,
              onRetry: () => ref
                  .read(
                    illustDetailControllerProvider(widget.illustId).notifier,
                  )
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
      ),
    );
  }

  /// The no-snapshot skeleton hands over to the content with a fade. Empty
  /// and error states fade in by themselves; the snapshot-first path never
  /// shows the skeleton, so the Hero destination is never faded.
  Widget _fadeStates(Widget body) =>
      StateFade(kind: body is IllustDetailSkeleton, child: body);

  /// The page-selection mode's top bar: the count, select all, and
  /// download; close (or system back) leaves the mode.
  PreferredSizeWidget _buildSelectionAppBar(
    BuildContext context,
    IllustEntity entity,
  ) {
    final l10n = context.l10n;
    final selected = _selectedPages ?? const <int>{};
    return selectionAppBar(
      context,
      count: selected.length,
      onClose: _exitDownloadMode,
      actions: [
        IconButton(
          tooltip: l10n.selectAll,
          onPressed: () => _selectAllPages(entity),
          icon: const Icon(Icons.select_all),
        ),
        IconButton(
          tooltip: l10n.downloadSelectedPages,
          onPressed: selected.isEmpty
              ? null
              : () => unawaited(_submitSelection(entity)),
          icon: const Icon(Icons.file_download_outlined),
        ),
      ],
    );
  }

  bool _rendersContent(
    AsyncValue<IllustDetailState> async,
    IllustEntity? entity,
  ) =>
      entity != null &&
      async.value is! IllustDetailRestricted &&
      async.value is! IllustDetailNotFound;

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    AsyncValue<IllustDetailState> async, {
    required bool immersive,
  }) {
    final entity = _entityOf(async);
    // Restricted and not-found states render a FeedEmpty body without an
    // InfoBlock — the menu's artwork-info item only exists while the
    // content actually renders.
    final rendersContent = _rendersContent(async, entity);
    return AppTopBar(
      // Over the artwork the bar shows nothing but controls; the work's
      // title fades in with the surface once the image scrolls away. The
      // opaque layouts keep a generic label: the real title wraps freely
      // in InfoBlock.
      title: Text(
        immersive && entity != null
            ? entity.title
            : context.l10n.illustDetailTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      immersion: immersive ? _immersion : null,
      entrance: immersive ? _topBarEntrance : null,
      // Download and bookmark live in the floating action bar.
      actions: [
        if (entity != null)
          _DetailMoreMenu(
            actions: [
              _DetailMenuAction.share,
              if (entity.pageCount > 1 && !entity.isUgoira)
                _DetailMenuAction.selectPages,
              if (rendersContent) _DetailMenuAction.info,
            ],
            onSelected: (buttonContext, action) => switch (action) {
              _DetailMenuAction.share => unawaited(
                _share(buttonContext, ref, entity),
              ),
              _DetailMenuAction.selectPages => _enterDownloadMode(),
              _DetailMenuAction.info => unawaited(_scrollToInfo()),
            },
          ),
      ],
    );
  }

  /// Every page, deduplicated by the manager. Any submission failure is
  /// shown: manager, ownership and channel errors would otherwise vanish.
  Future<void> _downloadAll(IllustEntity entity) async {
    final DownloadGroupSubmission submission;
    try {
      submission = await ref
          .read(illustDownloadControllerProvider)
          .downloadAll(entity);
    } catch (error) {
      if (!mounted) return;
      AppHaptics.error();
      showErrorSnackBar(
        context,
        action: context.l10n.downloadSubmissionFailed,
        error: error,
      );
      return;
    }
    if (!mounted) return;
    showDownloadSubmittedSnackBar(
      context,
      alreadyQueued: submission.group == null,
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
    // An illustration set opens on its first image; manga reads in full.
    final collapsible =
        entity.type == IllustType.illust && entity.pageCount > 1;
    final shownPages = collapsible && !_pagesExpanded ? 1 : entity.pageCount;
    // Narrow layout: the artwork runs under the status bar and the
    // see-through top bar, so overlays on it start below them, and the
    // bar draws in as the first image leaves.
    final topChrome = MediaQuery.paddingOf(context).top + kToolbarHeight;
    _topChromeExtent =
        AppBreakpoints.useTwoPaneDetail(MediaQuery.sizeOf(context).width)
        ? 0
        : topChrome;
    final firstImageExtent =
        MediaQuery.sizeOf(context).width / entity.pageAspectRatioAt(0);
    _immersionStart = math.max(
      0,
      firstImageExtent - topChrome - kToolbarHeight,
    );
    // Where a collapsed set ends: page 1's bottom just under the top bar.
    final firstPageEnd = math.max(0.0, firstImageExtent - topChrome);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateImmersion();
    });

    final imageSlivers = <Widget>[
      if (entity.isUgoira)
        SliverToBoxAdapter(
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
            tier: entity.imageTierOf(detailUrlFor(0) ?? entity.imageUrls.large),
          ),
        )
      else
        // Single and multi-page works share this one sliver: a snapshot
        // whose page count differs from the detail payload (a restored
        // feed, a work edited since) would otherwise swap the sliver type
        // mid-flight and orphan the Hero's landing spot.
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => Padding(
              padding: index == shownPages - 1
                  ? EdgeInsets.zero
                  : const EdgeInsets.only(bottom: FuncSpacing.sm),
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
                  overlayTopInset: index == 0 ? topChrome : 0,
                ),
              ),
            ),
            // All pages appear immediately: before the detail payload the
            // non-first pages render as neutral placeholders (uniform
            // ratio), and the real images/proportions replace them when
            // the detail API payload is merged.
            childCount: shownPages,
          ),
        ),
      // Selecting keeps every page on screen: no folding mid-selection.
      if (collapsible && !(_pagesExpanded && _downloadMode))
        SliverToBoxAdapter(
          child: _PagesToggleButton(
            count: entity.pageCount,
            expanded: _pagesExpanded,
            onPressed: _pagesExpanded
                ? () => _collapsePages(firstPageEnd)
                : () => setState(() => _pagesExpanded = true),
          ),
        ),
    ];
    final metaSlivers = <Widget>[
      // Official client behaviour: when the work belongs to an
      // illust series, the series card sits between the image pages
      // and the info block (name, 第 N 话, prev/next navigation).
      IllustSeriesSection(illustId: widget.illustId),
      SliverToBoxAdapter(
        // The ⋮ menu's artwork-info item scrolls to this anchor
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
      // Comment preview and the author's other works; like related works,
      // each asks for its data only once it is on screen.
      CommentsPreviewSlivers(illustId: widget.illustId),
      AuthorWorksSlivers(entity: entity),
      // Official client behaviour: "関連作品" below the caption/tags,
      // paginated as the user scrolls to the bottom of the page.
      RelatedIllustsSlivers(illustId: widget.illustId),
      // The page's end clears the floating action bar.
      SliverToBoxAdapter(
        child: SizedBox(height: DetailActionBar.restingExtent(context)),
      ),
    ];

    // Related works paginate as the user reaches the bottom of the page
    // (official client behaviour). loadMore is internally guarded against
    // re-entry / exhausted state.
    bool onScrollNotification(ScrollNotification notification) {
      _onBarScroll(notification);
      final metrics = notification.metrics;
      if (metrics.maxScrollExtent > 0 &&
          metrics.pixels >= metrics.maxScrollExtent - 500) {
        // The first page is requested by the related section once it is
        // on screen; this check must never be the first request, so it
        // only looks at a list that already exists. loadMore asserts an
        // AsyncData state (it calls requireValue), so it also waits for
        // the first page to land.
        final related = relatedIllustControllerProvider(widget.illustId);
        if (ref.exists(related) && ref.read(related).hasValue) {
          ref.read(related.notifier).loadMore();
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
          : Stack(
              fit: StackFit.expand,
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: onScrollNotification,
                  child: SmoothWheelScroll(
                    controller: _narrowScroll,
                    builder: (context, controller, physics) => CustomScrollView(
                      controller: controller,
                      physics: physics,
                      slivers: [...imageSlivers, ...metaSlivers],
                    ),
                  ),
                ),
                // The shared page counter floats over the top-end of the
                // artwork while an image page is actually on screen and
                // fades out once the last page scrolls away. The
                // pill is IgnorePointer, so taps fall through to the
                // artwork below. Selection mode hides it: each page's
                // badge occupies the same top-end corner. Single-page
                // works get no pill.
                if (!entity.isUgoira && entity.pageCount > 1 && !_downloadMode)
                  Positioned.fill(
                    top: topChrome,
                    child: ValueListenableBuilder<int?>(
                      valueListenable: _topVisiblePage,
                      builder: (context, page, _) => DetailPageCounter(
                        page: page,
                        count: entity.pageCount,
                        onCollapse: collapsible && _pagesExpanded
                            ? () => _collapsePages(firstPageEnd)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
    );
    final page = Stack(
      fit: StackFit.expand,
      children: [
        content,
        // The selection mode brings its own download; the bar steps aside.
        if (!_downloadMode)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DetailActionBar(
              entity: entity,
              visibility: _barCurve,
              onDownload: () => unawaited(_downloadAll(entity)),
              onComments: () =>
                  unawaited(openIllustComments(context, entity.id)),
            ),
          ),
      ],
    );
    final container = ProviderScope.containerOf(context, listen: false);
    final accountId = ref.watch(historyAccountIdProvider);
    if (accountId == null) return page;
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
      isAccountCurrent: () =>
          container.read(historyAccountIdProvider) == accountId,
      child: page,
    );
  }
}

/// Under the first image of a collapsed illustration set: shows the rest.
/// Once expanded it follows the last page and folds the set back.
class _PagesToggleButton extends StatelessWidget {
  const _PagesToggleButton({
    required this.count,
    required this.expanded,
    required this.onPressed,
  });

  final int count;
  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // One node: the button announces whether the set is expanded.
    return MergeSemantics(
      child: Semantics(
        expanded: expanded,
        child: TextButton.icon(
          key: Key(expanded ? 'illust-collapse-pages' : 'illust-expand-pages'),
          style: TextButton.styleFrom(
            minimumSize: const Size.fromHeight(kMinInteractiveDimension),
          ),
          onPressed: onPressed,
          icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          iconAlignment: IconAlignment.end,
          label: Text(
            expanded
                ? context.l10n.detailCollapsePages
                : context.l10n.detailExpandPages(count),
          ),
        ),
      ),
    );
  }
}

/// Actions carried by the detail AppBar's ⋮ menu: share, the page-
/// selection entry (multi-page works only) and the artwork-info jump.
enum _DetailMenuAction { share, selectPages, info }

/// The ⋮ menu holding the less-frequent detail actions. Every entry
/// carries an icon plus its localized text label — nothing here depends
/// on a long-press to be discoverable (R3).
class _DetailMoreMenu extends StatelessWidget {
  const _DetailMoreMenu({required this.actions, required this.onSelected});

  final List<_DetailMenuAction> actions;

  /// Receives the ⋮ button's own context so share can anchor its popover
  /// to the button.
  final void Function(BuildContext buttonContext, _DetailMenuAction action)
  onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    (IconData, String) labelOf(_DetailMenuAction action) => switch (action) {
      _DetailMenuAction.share => (Icons.share_outlined, l10n.cardActionShare),
      _DetailMenuAction.selectPages => (
        Icons.checklist_outlined,
        l10n.downloadSelectPages,
      ),
      _DetailMenuAction.info => (Icons.info_outline, l10n.illustInfoJump),
    };
    return AppMenuButton<_DetailMenuAction>(
      onSelected: onSelected,
      entries: [
        for (final action in actions)
          AppMenuEntry(
            value: action,
            icon: labelOf(action).$1,
            label: labelOf(action).$2,
          ),
      ],
    );
  }
}
