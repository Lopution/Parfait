import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/haptics/app_haptics.dart';
import '../../../app/icons/app_icons.dart';
import '../../../app/icons/ui_icons.dart';
import '../../../app/layout/app_breakpoints.dart';
import '../../../app/motion/motion_tokens.dart';
import '../../../app/motion/scroll_hide.dart';
import '../../../app/motion/state_fade.dart';
import '../../../app/navigation/home_shell_metrics.dart';
import '../../../app/navigation/route_animation.dart';
import '../../../app/navigation/route_facade.dart';
import '../../../app/pull_to_refresh.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/comment_composer.dart';
import '../../../app/widgets/errors/error_details.dart' show showErrorSnackBar;
import '../../../app/widgets/feed/desktop_inspector_scope.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../core/auth/account_store.dart';
import '../../../core/debug/frame_probe.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart' show DownloadEvent;
import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/illust/illust_detail_controller.dart';
import '../../../core/illust/illust_download_controller.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../illust_actions.dart';
import 'illust_detail_menu.dart';
import 'illust_detail_scroll.dart';
import 'illust_detail_shells.dart';
import 'related_illusts_section.dart';
import 'widgets/detail_action_bar.dart';
import 'widgets/detail_comment_layer.dart';
import 'widgets/detail_overlay_frame.dart';
import 'widgets/illust_detail_skeleton.dart';

export '../../../app/widgets/feed/desktop_inspector_scope.dart'
    show IllustEmbeddedBackController;
export 'illust_detail_scroll.dart' show detailFirstImageFrame;

class IllustDetailPage extends ConsumerStatefulWidget {
  const IllustDetailPage({
    super.key,
    required this.illustId,
    this.initialEntity,
    this.heroScope = 'feed',
    this.heroImageUrl,
    this.heroImageDecodeWidth,
    this.embeddedInspector = false,
    this.onCloseInspector,
    this.onOpenFullStage,
    this.embeddedBackController,
  });

  final int illustId;
  final IllustEntity? initialEntity;
  final String heroScope;
  final String? heroImageUrl;

  /// The feed card's decode width for [heroImageUrl] — decoding the hero
  /// phase at this width reuses the feed's decoded cache entry, so the
  /// landing frame does not re-decode the same file at screen width.
  final int? heroImageDecodeWidth;

  /// True when hosted inside the desktop side inspector rather than a route.
  final bool embeddedInspector;
  final VoidCallback? onCloseInspector;
  final ValueChanged<IllustEntity>? onOpenFullStage;
  final IllustEmbeddedBackController? embeddedBackController;

  @override
  ConsumerState<IllustDetailPage> createState() => _IllustDetailPageState();
}

class _IllustDetailPageState extends ConsumerState<IllustDetailPage>
    with TickerProviderStateMixin {
  final IllustDetailScrollController _scroll = IllustDetailScrollController();

  /// Page indexes selected in the explicit download-selection mode;
  /// `null` means the mode is off.
  Set<int>? _selectedPages;

  /// The floating action bar's presence (1 shown).
  late final AnimationController _barVisibility = AnimationController(
    vsync: this,
    value: widget.embeddedInspector || widget.heroImageUrl == null ? 1 : 0,
  );
  final _scrollHide = ScrollHideTracker();

  bool _composing = false;
  final _composerKey = GlobalKey<CommentComposerState>();
  bool _touchExploration = false;

  late final AnimationController _topBarEntrance = AnimationController(
    vsync: this,
    value: widget.embeddedInspector || widget.heroImageUrl == null ? 1 : 0,
  );
  Animation<double>? _routeAnimation;
  bool _entered = false;

  /// Cross-breakpoint layout switch fade (running from current opacity on
  /// rapid drags across the breakpoint so the page never flashes).
  late final AnimationController _layoutFade = AnimationController(
    vsync: this,
    value: 1,
  );
  late final Animation<double> _layoutFadeOpacity = Tween(
    begin: 0.55,
    end: 1.0,
  ).animate(_layoutFade);

  bool _blockMode = false;
  bool _pagesExpanded = false;
  StreamSubscription<DownloadEvent>? _downloadEvents;

  @override
  void initState() {
    super.initState();
    widget.embeddedBackController?.handler = _handleEmbeddedBack;
    _downloadEvents = ref.read(downloadManagerProvider).events.listen((event) {
      if (mounted && event.snapshot.illustId == widget.illustId) {
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(IllustDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.embeddedBackController != widget.embeddedBackController) {
      if (oldWidget.embeddedBackController?.handler == _handleEmbeddedBack) {
        oldWidget.embeddedBackController?.handler = null;
      }
      widget.embeddedBackController?.handler = _handleEmbeddedBack;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _barVisibility.duration = MotionTokens.resolve(
      context,
      MotionTokens.chrome,
    );
    _touchExploration = MediaQuery.accessibleNavigationOf(context);
    if (_touchExploration && !_downloadMode && !_composing) {
      _barVisibility.value = 1;
    }
    _topBarEntrance.duration = MotionTokens.resolve(
      context,
      MotionTokens.chrome,
    );
    // Reduced motion turned on mid-fade lands the page at once (MOTION-02).
    if (_layoutFade.value < 1 &&
        MotionTokens.resolve(context, MotionTokens.branchSwitch) ==
            Duration.zero) {
      _layoutFade.value = 1;
    }
    final route = RouteAnimationScope.of(context);
    if (!identical(route, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_onRouteStatus);
      _routeAnimation = route?..addStatusListener(_onRouteStatus);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _onRouteStatus(_routeAnimation?.status ?? AnimationStatus.completed);
        }
      });
    }
    _syncTwoPaneTransitionIfNeeded();
  }

  /// Handles breakpoint crossings in `didChangeDependencies` (where
  /// `HomeShellChrome` and `MediaQuery` changes notify) so `build()` never
  /// triggers layout-fade animations or schedules scroll-sync side effects.
  void _syncTwoPaneTransitionIfNeeded() {
    final async = ref.read(illustDetailControllerProvider(widget.illustId));
    final entity = _entityOf(async);
    if (entity == null || !_rendersContent(async, entity)) return;
    final layout = IllustFirstImageLayout.of(
      context,
      entity,
      expanded: _pagesExpanded,
      embeddedInspector: widget.embeddedInspector,
    );
    final twoPane = layout.useTwoPane;
    final wasTwoPane = _scroll.lastTwoPane;
    final prevTopChromeExtent = _scroll.topChromeExtent;
    _scroll.lastTwoPane = twoPane;
    _scroll.topChromeExtent = twoPane ? 0 : layout.topChrome;
    _scroll.immersionStart = layout.immersionStart;
    _scroll.schedulePostLayoutSync();
    if (wasTwoPane == true && !twoPane) {
      final metaOffset = _scroll.metaScroll.hasClients
          ? _scroll.metaScroll.offset
          : _scroll.lastMetaOffset;
      if (metaOffset > 0) {
        _scroll.scheduleNarrowMetaSync(metaOffset, isMounted: () => mounted);
      } else {
        _scroll.scheduleNarrowReveal(
          getContext: () => context,
          isMounted: () => mounted,
          entity: entity,
          isPagesExpanded: () => _pagesExpanded,
          onExpandPages: _expandPages,
        );
      }
      _fadeLayoutIn(context);
    } else if (wasTwoPane == false && twoPane) {
      _scroll.cancelNarrowReveal();
      final index = _scroll.narrowTopImage(context, layout);
      if (index != null) _scroll.imageIndex = index;
      final metaOffset = _scroll.captureNarrowMetaOffset(prevTopChromeExtent);
      _scroll.lastMetaOffset = metaOffset;
      if (metaOffset > 0) {
        _scroll.scheduleMetaSync(metaOffset, isMounted: () => mounted);
      }
      _fadeLayoutIn(context);
    }
  }

  @override
  void dispose() {
    if (widget.embeddedBackController?.handler == _handleEmbeddedBack) {
      widget.embeddedBackController?.handler = null;
    }
    unawaited(_downloadEvents?.cancel());
    _scroll.dispose();
    _barVisibility.dispose();
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _topBarEntrance.dispose();
    _layoutFade.dispose();
    super.dispose();
  }

  bool _handleEmbeddedBack() {
    if (_composing) {
      final composer = _composerKey.currentState;
      composer == null ? _closeComposer() : composer.dismiss();
      return true;
    }
    if (_downloadMode) {
      _exitDownloadMode();
      return true;
    }
    if (_blockMode) {
      setState(() => _blockMode = false);
      return true;
    }
    return false;
  }

  void _onRouteStatus(AnimationStatus status) {
    if (_entered) return;
    if (status != AnimationStatus.forward && !status.isCompleted) return;
    _entered = true;
    _topBarEntrance.forward();
    if (!_touchExploration) {
      slideChrome(context, _barVisibility, hidden: false);
    }
  }

  void _fadeLayoutIn(BuildContext context) {
    final duration = MotionTokens.resolve(context, MotionTokens.branchSwitch);
    if (duration == Duration.zero) {
      _layoutFade.value = 1;
      return;
    }
    if (_layoutFade.value >= 1) _layoutFade.value = 0;
    FrameProbe.instance.enter('detail layout');
    final fade = _layoutFade.animateTo(
      1,
      duration: duration,
      curve: MotionTokens.branchSwitchCurve,
    );
    fade.whenCompleteOrCancel(() => FrameProbe.instance.exit('detail layout'));
    unawaited(fade);
  }

  void _collapsePages(double firstPageEnd) {
    _scroll.clampForCollapse(firstPageEnd);
    setState(() => _pagesExpanded = false);
    _scroll.schedulePostLayoutSync();
  }

  void _expandPagesFromSlot(double removedBand) {
    _scroll.compensateExpandedSlot(removedBand);
    _expandPages();
  }

  void _expandPages() {
    setState(() => _pagesExpanded = true);
    _scroll.schedulePostLayoutSync();
  }

  void _toggleBlockMode() => setState(() => _blockMode = !_blockMode);

  bool _onScrollNotification(ScrollNotification notification) {
    if (!_touchExploration && !_downloadMode && !_composing) {
      final hide = _scrollHide.update(
        notification,
        _barVisibility,
        travel: DetailActionBar.restingExtent(context),
      );
      if (hide != null) slideChrome(context, _barVisibility, hidden: hide);
    }
    final metrics = notification.metrics;
    if (metrics.maxScrollExtent > 0 &&
        metrics.pixels >= metrics.maxScrollExtent - 500) {
      final related = relatedIllustControllerProvider(widget.illustId);
      if (ref.read(related.exists) &&
          ref.read(related).value?.isAllHidden == false) {
        unawaited(ref.read(related.notifier).loadMore());
      }
    }
    return false;
  }

  bool get _downloadMode => _selectedPages != null;

  void _openComposer(CommentComposerInputState surface) {
    final signedIn =
        ref.read(accountStoreProvider).value?.usableCurrent != null;
    if (!signedIn) {
      unawaited(openLogin(context));
      return;
    }
    if (!_composing) {
      setState(() => _composing = true);
      slideChrome(context, _barVisibility, hidden: true);
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _composerKey.currentState?.open(surface),
    );
  }

  void _closeComposer() {
    if (!_composing || !mounted) return;
    setState(() => _composing = false);
    if (!_downloadMode) slideChrome(context, _barVisibility, hidden: false);
  }

  void _enterDownloadMode() {
    if (_downloadMode) return;
    AppHaptics.confirm();
    setState(() {
      _selectedPages = <int>{};
      _pagesExpanded = true;
    });
    _scroll.schedulePostLayoutSync();
    slideChrome(context, _barVisibility, hidden: true);
  }

  void _exitDownloadMode() {
    if (!_downloadMode) return;
    AppHaptics.select();
    setState(() => _selectedPages = null);
    slideChrome(context, _barVisibility, hidden: false);
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
    if (!_composing) slideChrome(context, _barVisibility, hidden: false);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<IllustDetailState>>(
      illustDetailControllerProvider(widget.illustId),
      (_, next) {
        final entity = _entityOf(next);
        if (entity != null && _rendersContent(next, entity)) {
          _syncTwoPaneTransitionIfNeeded();
        }
      },
    );
    final async = ref.watch(illustDetailControllerProvider(widget.illustId));
    final entity = _entityOf(async);
    final twoPane =
        !widget.embeddedInspector &&
        AppBreakpoints.useTwoPaneDetailOf(
          context,
          HomeShellChrome.contentSizeOf(context),
        );
    final rendersContent = entity != null && _rendersContent(async, entity);
    final hideTwoPaneAppBar = !_downloadMode && twoPane && rendersContent;
    final hideInspectorAppBar =
        !_downloadMode && widget.embeddedInspector && rendersContent;
    final immersive =
        !widget.embeddedInspector &&
        !twoPane &&
        (entity == null ? async.isLoading : rendersContent);
    return PopScope(
      canPop:
          widget.embeddedBackController != null ||
          (!_downloadMode && !_composing && !_blockMode),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleEmbeddedBack();
      },
      child: RefreshActionAnchor(
        onRefresh: () => ref
            .read(illustDetailControllerProvider(widget.illustId).notifier)
            .reload(),
        child: _wrapNarrowPrimaryScroll(
          enabled: !twoPane && !widget.embeddedInspector,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            extendBodyBehindAppBar: immersive,
            appBar: hideTwoPaneAppBar || hideInspectorAppBar
                ? null
                : _downloadMode && entity != null
                ? _buildSelectionAppBar(context, entity)
                : _buildAppBar(context, async, immersive: immersive),
            body: _fadeStates(
              async.when(
                loading: () {
                  final snapshot = _snapshotEntity();
                  if (snapshot != null) {
                    return _buildContent(context, snapshot);
                  }
                  return const IllustDetailSkeleton();
                },
                error: (Object error, StackTrace _) => FeedError(
                  title: context.l10n.illustDetailLoadFailed,
                  error: error,
                  retryLabel: context.l10n.retry,
                  onRetry: () => ref
                      .read(
                        illustDetailControllerProvider(
                          widget.illustId,
                        ).notifier,
                      )
                      .reload(),
                ),
                data: (state) => switch (state) {
                  IllustDetailRestricted(:final entity) => FeedEmpty(
                    icon: AppIcons.eyeOff,
                    title: context.l10n.illustDetailRestricted(entity.id),
                  ),
                  IllustDetailNotFound() => FeedEmpty(
                    icon: AppIcons.searchOff,
                    title: context.l10n.illustDetailNotFound,
                  ),
                  IllustDetailReady(:final entity) => _buildContent(
                    context,
                    entity,
                    detailReady: true,
                  ),
                  IllustDetailError(:final error, :final snapshot) =>
                    _errorOrSnapshot(context, error, snapshot),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wrapNarrowPrimaryScroll({
    required bool enabled,
    required Widget child,
  }) => enabled
      ? PrimaryScrollController(
          controller: _scroll.narrowScroll,
          automaticallyInheritForPlatforms: const {},
          child: child,
        )
      : child;

  Widget _fadeStates(Widget body) =>
      StateFade(kind: body is IllustDetailSkeleton, child: body);

  PreferredSizeWidget _buildSelectionAppBar(
    BuildContext context,
    IllustEntity entity,
  ) {
    final selected = _selectedPages ?? const <int>{};
    return buildIllustDetailSelectionAppBar(
      context,
      selectedCount: selected.length,
      onClose: _exitDownloadMode,
      onSelectAll: () => _selectAllPages(entity),
      onSubmit: selected.isEmpty
          ? null
          : () => unawaited(_submitSelection(entity)),
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
    final rendersContent = _rendersContent(async, entity);
    final twoPane =
        !widget.embeddedInspector &&
        AppBreakpoints.useTwoPaneDetailOf(
          context,
          HomeShellChrome.contentSizeOf(context),
        );
    if (widget.embeddedInspector) {
      return buildIllustDetailInspectorAppBar(
        context,
        entity: entity,
        moreMenu: entity == null
            ? null
            : _buildMoreMenu(
                entity,
                rendersContent: rendersContent,
                includeShare: true,
                includeInfoJump: false,
              ),
        onOpenFullStage: widget.onOpenFullStage,
        onCloseInspector: widget.onCloseInspector,
      );
    }
    final isModalOverlay = DetailOverlayFrame.isActiveOf(context);
    return AppTopBar(
      automaticallyImplyLeading: !isModalOverlay,
      title: SelectionContainer.disabled(
        child: Text(
          immersive && entity != null
              ? entity.title
              : context.l10n.illustDetailTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      immersion: immersive ? _scroll.immersion : null,
      overArtwork:
          entity == null ||
          IllustFirstImageLayout.of(
            context,
            entity,
            expanded: _pagesExpanded,
          ).artworkUnderBar,
      entrance: immersive ? _topBarEntrance : null,
      actions: [
        if (entity != null && (!twoPane || !rendersContent))
          _buildMoreMenu(
            entity,
            rendersContent: rendersContent,
            includeShare: true,
            includeInfoJump: !twoPane,
          ),
        if (isModalOverlay && (!twoPane || !rendersContent))
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            icon: const Icon(UiIcons.close),
            onPressed: () => unawaited(Navigator.maybePop(context)),
          ),
      ],
    );
  }

  Widget _buildMoreMenu(
    IllustEntity entity, {
    required bool rendersContent,
    required bool includeShare,
    required bool includeInfoJump,
  }) => buildIllustDetailMoreMenu(
    context: context,
    ref: ref,
    entity: entity,
    rendersContent: rendersContent,
    includeShare: includeShare,
    includeInfoJump: includeInfoJump,
    onSelectPages: _enterDownloadMode,
    onInfoJump: () => unawaited(_scroll.scrollToInfo(isMounted: () => mounted)),
  );

  Widget _buildContent(
    BuildContext context,
    IllustEntity entity, {
    bool detailReady = false,
  }) {
    final detailQuality = ref.watch(detailQualityProvider);
    String? detailUrlFor(int index) =>
        detailReady ? entity.detailUrlAt(index, detailQuality) : null;

    final layout = IllustFirstImageLayout.of(
      context,
      entity,
      expanded: _pagesExpanded,
      embeddedInspector: widget.embeddedInspector,
    );
    // Keep metrics aligned on initial first-content build (when no dependency
    // change occurred yet after snapshot/data arrival).
    _scroll.topChromeExtent = layout.useTwoPane ? 0 : layout.topChrome;
    _scroll.immersionStart = layout.immersionStart;
    _scroll.lastTwoPane ??= layout.useTwoPane;

    final imageSlivers = buildIllustDetailImageSlivers(
      entity: entity,
      layout: layout,
      scroll: _scroll,
      heroScope: widget.heroScope,
      heroImageUrl: widget.heroImageUrl,
      heroImageDecodeWidth: widget.heroImageDecodeWidth,
      detailReady: detailReady,
      detailUrlFor: detailUrlFor,
      downloadMode: _downloadMode,
      selectedPages: _selectedPages,
      pagesExpanded: _pagesExpanded,
      onTogglePageSelected: _togglePageSelected,
      onEnterDownloadMode: _enterDownloadMode,
      onCollapsePages: () => _collapsePages(layout.firstPageEnd),
      onExpandPages: () => _expandPagesFromSlot(layout.alone - layout.natural),
    );
    final metaSlivers = buildIllustDetailMetaSlivers(
      context,
      illustId: widget.illustId,
      entity: entity,
      infoAnchorKey: _scroll.infoAnchorKey,
      blockMode: _blockMode,
      onToggleBlockMode: _toggleBlockMode,
      onCompose: _openComposer,
      twoPane: layout.useTwoPane,
      embeddedInspector: widget.embeddedInspector,
    );
    final composerLayer = _composing
        ? Positioned.fill(
            child: SelectionContainer.disabled(
              child: DetailCommentLayer(
                illustId: widget.illustId,
                composerKey: _composerKey,
                onClose: _closeComposer,
              ),
            ),
          )
        : null;

    final Widget layoutBody;
    if (layout.useTwoPane) {
      layoutBody = IllustDetailTwoPaneShell(
        entity: entity,
        detailUrlFor: detailUrlFor,
        downloadMode: _downloadMode,
        selectedPages: _selectedPages ?? const <int>{},
        onToggleSelect: _togglePageSelected,
        onLongPress: _enterDownloadMode,
        heroScope: widget.heroScope,
        initialPage: _scroll.imageIndex,
        onPageChanged: (page) => _scroll.imageIndex = page,
        heroImageUrl: widget.heroImageUrl,
        heroImageDecodeWidth: widget.heroImageDecodeWidth,
        inspectorHeader: DetailInspectorHeader(
          entity: entity,
          moreMenu: _buildMoreMenu(
            entity,
            rendersContent: true,
            includeShare: false,
            includeInfoJump: false,
          ),
        ),
        metaScrollController: _scroll.metaScroll,
        metaSlivers: metaSlivers,
        onScrollNotification: _onScrollNotification,
        composerLayer: composerLayer,
      );
    } else {
      final singleColumn = IllustDetailSingleColumnScroll(
        entity: entity,
        scrollController: _scroll.narrowScroll,
        slivers: [...imageSlivers, ...metaSlivers],
        onScrollNotification: _onScrollNotification,
        downloadMode: _downloadMode,
        forceSelectionArea: widget.embeddedInspector,
        topChrome: layout.topChrome,
        topVisiblePage: _scroll.topVisiblePage,
        pagesToggleOnScreen: _scroll.pagesToggleOnScreen,
        canCollapseFromPill: layout.collapsible && _pagesExpanded,
        onCollapsePages: () => _collapsePages(layout.firstPageEnd),
      );
      if (widget.embeddedInspector) {
        layoutBody = IllustDetailEmbeddedInspectorShell(
          downloadMode: _downloadMode,
          header: DetailEmbeddedInspectorHeader(
            entity: entity,
            moreMenu: _buildMoreMenu(
              entity,
              rendersContent: true,
              includeShare: false,
              includeInfoJump: true,
            ),
            onOpenFullStage: widget.onOpenFullStage,
            onCloseInspector: widget.onCloseInspector,
          ),
          body: singleColumn,
          composerLayer: composerLayer,
        );
      } else {
        layoutBody = IllustDetailNarrowShell(
          entity: entity,
          body: singleColumn,
          barVisibility: _barVisibility,
          onDownloadAll: () =>
              unawaited(downloadAllIllustPages(context, ref, entity)),
          composerLayer: composerLayer,
        );
      }
    }

    final page = FadeTransition(
      key: const ValueKey('detail-layout-fade'),
      opacity: _layoutFadeOpacity,
      child: layoutBody,
    );
    return IllustDetailHistoryScope(entity: entity, child: page);
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
    Object error,
    IllustEntity? snapshot,
  ) {
    final entity = snapshot ?? _snapshotEntity();
    if (entity != null) return _buildContent(context, entity);
    return FeedError(
      title: context.l10n.illustDetailLoadFailed,
      error: error,
      retryLabel: context.l10n.retry,
      onRetry: () => ref
          .read(illustDetailControllerProvider(widget.illustId).notifier)
          .reload(),
    );
  }
}
