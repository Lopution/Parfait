import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/clipboard.dart';
import '../../../app/format/app_format.dart';
import '../../../app/layout/app_breakpoints.dart';
import '../../../app/layout/input_modality.dart';
import '../../../app/motion/drag_to_dismiss.dart';
import '../../../app/widgets/app_spinner.dart';
import '../../../app/haptics/app_haptics.dart';
import '../../../app/motion/app_overlays.dart';
import '../../../app/motion/motion_tokens.dart';
import '../../../app/navigation/home_shell_metrics.dart';
import '../../../app/navigation/route_animation.dart';
import '../../../app/navigation/route_facade.dart';
import '../../../app/navigation/viewer_session.dart';
import '../../../app/motion/hero_transition.dart';
import '../../../app/person_avatar.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/scroll_behavior.dart';
import '../../../app/widgets/app_slider.dart';
import '../../../app/widgets/display_actions.dart';
import '../../../core/entity/illust_caption.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart' show DownloadEvent;
import '../../../core/illust/illust_download_controller.dart';
import '../illust_actions.dart';
import '../../../core/image/image_demand.dart';
import '../../../core/image/image_worker_providers.dart';
import '../../../core/platform/image_clipboard.dart';
import '../../../app/system_ui.dart';
import '../../../app/theme/func_tokens.dart';
import '../../../app/theme/replica_theme.dart';
import '../../../l10n/lookup.dart';
import '../../../app/widgets/artwork_controls.dart';
import '../../../app/widgets/entity_row.dart' show EntityBadge;
import '../../../app/widgets/feed/feed_states.dart' show FeedLoading;
import '../../../app/widgets/errors/error_details.dart';
import '../../../app/window/desktop_command_bar_scope.dart';
import '../../../app/window/desktop_title_bar.dart';
import '../../../l10n/context.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../detail/widgets/detail_page_counter.dart' show PageCountPill;
import '../../../app/icons/app_icons.dart';
import '../../../app/icons/ui_icons.dart';

export '../../../app/navigation/viewer_session.dart'
    show beginImageViewerSession, debugResetViewerSession;
export '../../../app/window/desktop_command_bar_scope.dart'
    show DesktopCommandBarScope;

part 'image_viewer_chrome.dart';

/// Fullscreen horizontal viewer replicating beta56 ImageScalePage
/// (R3): `n / total` counter in the top bar, horizontal paging, per-page zoom clamped to
/// 0.9–6.0, initial page restored, swiping suspended while zoomed.
class ImageViewerPage extends ConsumerStatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.urls,
    this.initialPage = 0,
    this.heroTagForPage,
    this.onPageChanged,
    this.tierKeyForPage,
    this.tier,
    this.prefetchUrlForPage,
    this.entity,
    this.loading = false,
    this.failure,
  }) : assert(initialPage >= 0);

  final List<String> urls;
  final int initialPage;
  final Object? Function(int page)? heroTagForPage;
  final ValueChanged<int>? onPageChanged;

  /// Per-(work,page) tier registry key + requested tier, so viewer images can
  /// be served from an already-cached higher tier and so the flight back to
  /// detail reuses the same transition history.
  final String? Function(int page)? tierKeyForPage;
  final IllustImageTier? tier;

  /// Medium-tier URL for a page, used to warm the neighbours of the active
  /// page (3b): swiping forward/back lands on an already-decoded underlay
  /// instead of a black placeholder.
  final String? Function(int page)? prefetchUrlForPage;

  /// The resolved work entity powering save/share/info. Null on a cold
  /// deep-link or when the store has not loaded the work yet — in that case
  /// the entity-bound actions simply do not render.
  final IllustEntity? entity;

  /// The pages are still on their way: a viewer restored with no work in
  /// memory gets them from the detail. Until [initialPage] is among [urls]
  /// the viewer has no pages and shows a spinner, its exits in place; it
  /// then opens on that page.
  final bool loading;

  /// Shown instead of "no images" when the pages could not be loaded: the
  /// route's failure view, with its retry. The exits stay in place.
  final Widget? failure;

  /// Zoom bounds (PRD R3: strictly 0.9–6.0).
  static const double minScale = 0.9;
  static const double maxScale = 6.0;

  /// A page first decodes at twice the screen's width, sharp up to a 2x
  /// zoom, instead of the whole file: an original is thousands of pixels
  /// on a side, tens of megabytes decoded, and slow to decode on a swipe.
  static const previewScale = 2.0;

  /// The zoom at which a page decodes the whole file, from then on: early
  /// enough that it is ready before the preview runs out of pixels.
  static const fullDecodeScale = 1.5;

  /// The decode width of a page's preview; [openImageViewer] warms the same.
  static int previewDecodeWidth(BuildContext context) =>
      viewerPreviewDecodeWidth(context);

  @override
  ConsumerState<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends ConsumerState<ImageViewerPage>
    with SingleTickerProviderStateMixin {
  late PageController _pageController;
  late final AnimationController _zoomController;
  final _transformations = <int, TransformationController>{};

  /// Pages zoomed past [ImageViewerPage.fullDecodeScale]: they keep the
  /// whole-file decode, so a zoom around the threshold never swaps back.
  final _fullDecode = <int>{};

  /// Per-page download progress for the ring over the page.
  final _progress = <int, ValueNotifier<ImageLoadProgress>>{};
  int _activePage = 0;

  /// Set as a drag-to-dismiss pops the route; read by [_ExitSlide].
  bool _dismissedByDrag = false;

  /// The page controller currently being zoom-animated and the tween
  /// driving it (focal zoom → Matrix4, not a scalar scale).
  TransformationController? _zoomTarget;
  int? _zoomTargetPage;
  Tween<Matrix4>? _zoomTween;
  late final CurvedAnimation _zoomCurve;
  final _targetZoomMatrices = <int, Matrix4>{};
  final _stageKey = GlobalKey();

  /// Focal point of the in-flight double tap, in viewport coordinates.
  Offset? _doubleTapFocal;

  /// Download badges/spinners derive from live manager tasks; the manager
  /// itself is not listenable, so this subscription is what makes the
  /// save action reflect downloading/exist/error as they happen (same
  /// contract as the detail page's `_ensureDownloadListener`).
  StreamSubscription<DownloadEvent>? _downloadEvents;

  /// Where [_prefetchNeighbours] registered its window, cleared on dispose.
  ImageDemand? _prefetchDemand;

  /// The page represented by the scrubber while the thumb is down. Keeping
  /// this separate from [_activePage] is what makes a long drag cheap: the
  /// PageView does not build or decode every page between the endpoints.
  int? _scrubPage;

  /// The last pointer that went down on the scrubber. Its Listener sits
  /// below [DragToDismiss] in the hit path, so it records the pointer
  /// before the dismiss recognizer is offered it and turns it away.
  int? _scrubPointer;
  bool _stageHovered = false;
  bool _pointerChromeRevealed = false;
  bool _chromeHotzoneHovered = false;
  bool _scrubberHovered = false;
  bool _infoPanelOpen = false;
  Timer? _chromeHideTimer;
  DesktopCommandBarController? _commandBarController;
  ModalRoute<dynamic>? _observedRoute;
  Animation<double>? _observedAnimation;

  int get _pageCount => _pagesOf(widget);

  static int _pagesOf(ImageViewerPage viewer) =>
      viewer.loading && viewer.initialPage >= viewer.urls.length
      ? 0
      : viewer.urls.length;

  bool get _chromeVisible =>
      viewerSessionChromeVisible || _pointerChromeRevealed;

  @override
  void initState() {
    super.initState();
    // Empty URL list has no pages to clamp against; keep the title at
    // "1 / 0" and let the placeholder body render (R6: no crash).
    _activePage = _pageCount == 0
        ? 0
        : widget.initialPage.clamp(0, _pageCount - 1);
    _pageController = PageController(initialPage: _activePage);
    _zoomController = AnimationController(vsync: this)
      ..addListener(_applyZoomFrame)
      ..addStatusListener(_onZoomStatus);
    _zoomCurve = CurvedAnimation(
      parent: _zoomController,
      curve: MotionTokens.spatialCurve,
    );
    _pageController.addListener(_onPageChanged);
    _transformationFor(_activePage).addListener(_onTransformed);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _prefetchNeighbours(_activePage),
    );
    if (!viewerSessionChromeVisible) _setSystemChrome(visible: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextController = DesktopCommandBarScope.controllerOf(context);
    if (!identical(_commandBarController, nextController)) {
      _commandBarController?.setHidden(this, false);
      _commandBarController = nextController;
    }
    final nextRoute = ModalRoute.of(context);
    final nextAnimation =
        RouteAnimationScope.of(context) ?? nextRoute?.animation;
    _observedRoute = nextRoute;
    if (!identical(_observedAnimation, nextAnimation)) {
      _observedAnimation?.removeStatusListener(_onRouteAnimationStatus);
      _observedAnimation = nextAnimation;
      _observedAnimation?.addStatusListener(_onRouteAnimationStatus);
    }
    _syncCommandBarHidden();
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    _syncCommandBarHidden();
  }

  void _syncCommandBarHidden() {
    final controller = _commandBarController;
    if (controller == null) return;
    final anim = _observedAnimation;
    final route = _observedRoute;
    // Keep the command bar hidden throughout reverse playback until the
    // transition fully dismisses (Route.isActive flips false as soon as pop
    // starts, which would push the fading dark stage down by 48px).
    final active =
        mounted &&
        (anim != null
            ? anim.status != AnimationStatus.dismissed
            : (route == null || route.isActive));
    controller.setHidden(this, active);
  }

  @override
  void didUpdateWidget(covariant ImageViewerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The pages arrived: the pager was never built, so it opens on the
    // page asked for instead of the one initState clamped to.
    if (_pagesOf(oldWidget) > 0 || _pageCount == 0) return;
    _targetZoomMatrices.clear();
    _transformationFor(_activePage).removeListener(_onTransformed);
    _activePage = widget.initialPage.clamp(0, _pageCount - 1);
    _transformationFor(_activePage).addListener(_onTransformed);
    _pageController
      ..removeListener(_onPageChanged)
      ..dispose();
    _pageController = PageController(initialPage: _activePage)
      ..addListener(_onPageChanged);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _prefetchNeighbours(_activePage),
    );
  }

  /// The download manager publishes task changes on a stream rather than
  /// through listenable state — without this the save button's
  /// `stateFor` badge (spinner/check/error) would only refresh when some
  /// unrelated rebuild happens. Only installed once an entity exists —
  /// the badge it feeds never renders without one (this also keeps the
  /// viewer usable in ProviderScope-less harnesses, where no entity can
  /// ever arrive).
  void _ensureDownloadListener() {
    // Only this work's, as on the detail page.
    _downloadEvents ??= ref.read(downloadManagerProvider).events.listen((
      event,
    ) {
      if (mounted && event.snapshot.illustId == widget.entity?.id) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _observedAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _observedAnimation = null;
    _observedRoute = null;
    _commandBarController?.setHidden(this, false);
    _commandBarController = null;
    _chromeHideTimer?.cancel();
    _prefetchDemand?.clearPrefetchWindow(this);
    unawaited(_downloadEvents?.cancel());
    for (final controller in _transformations.values) {
      controller.dispose();
    }
    for (final progress in _progress.values) {
      progress.dispose();
    }
    _zoomCurve.dispose();
    _zoomController.dispose();
    _pageController.dispose();
    if (!viewerSessionChromeVisible) _setSystemChrome(visible: true);
    super.dispose();
  }

  void _onPageChanged() {
    final page = _pageController.page?.round() ?? _activePage;
    if (page != _activePage) {
      _targetZoomMatrices.clear();
      setState(() {
        _transformationFor(_activePage).removeListener(_onTransformed);
        _activePage = page;
        _transformationFor(_activePage).addListener(_onTransformed);
      });
      widget.onPageChanged?.call(page);
      _prefetchNeighbours(page);
    }
  }

  /// Warm the medium tier of the pages next to [page]: a page turn then
  /// lands on an already-decoded underlay instead of black while the
  /// requested tier streams in. Best-effort — errors are swallowed by
  /// [PixivImage.preload] itself resolving through the shared provider.
  void _prefetchNeighbours(int page) {
    final urlFor = widget.prefetchUrlForPage;
    if (urlFor == null || !mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final neighbours = <int, String>{
      for (final neighbour in [page - 1, page + 1])
        if (neighbour >= 0 && neighbour < _pageCount)
          neighbour: ?urlFor(neighbour),
    };
    // A page turn replaces the window: a still-queued warm-up for a page
    // the user swiped away from is dropped. The neighbours load through the
    // image worker, so the window is the worker's.
    final demand = container.read(imageWorkerProvider).demand
      ..setPrefetchWindow(this, neighbours.values.toSet());
    _prefetchDemand = demand;
    for (final MapEntry(key: neighbour, value: url) in neighbours.entries) {
      unawaited(
        PixivImage.preload(
          context,
          url,
          tierKey: widget.tierKeyForPage?.call(neighbour),
          tier: IllustImageTier.medium,
        ).catchError((_) => ImagePreloadResult.failed),
      );
    }
  }

  void _onScrubChanged(double value) {
    final page = value.round().clamp(0, _pageCount - 1);
    if (_scrubPage == page) return;
    setState(() => _scrubPage = page);
    _prefetchScrubWindow(page);
  }

  void _onScrubEnd(double value) {
    final page = value.round().clamp(0, _pageCount - 1);
    setState(() => _scrubPage = null);
    if (page != _activePage && mounted) _pageController.jumpToPage(page);
  }

  /// Scrubbing only warms the square thumbnails the bubble shows beside the
  /// thumb. It never asks for a viewer tier, so pages crossed during a drag
  /// cannot trigger a chain of full-size decodes; a viewer opened without
  /// an entity has no thumbnails and warms nothing.
  void _prefetchScrubWindow(int page) {
    final entity = widget.entity;
    if (!mounted || entity == null) return;
    final urls = <int, String>{};
    for (final candidate in [page - 1, page, page + 1]) {
      if (candidate < 0 || candidate >= _pageCount) continue;
      final url = entity.squareUrlAt(candidate);
      if (url != null && url.isNotEmpty) urls[candidate] = url;
    }
    if (urls.isEmpty) return;
    final demand =
        ProviderScope.containerOf(
            context,
            listen: false,
          ).read(imageWorkerProvider).demand
          ..setPrefetchWindow(this, urls.values.toSet());
    _prefetchDemand = demand;
    for (final entry in urls.entries) {
      unawaited(
        PixivImage.preload(
          context,
          entry.value,
          memCacheWidth: PixivImage.decodeWidthOf(
            context,
            _PageScrubber.thumbnailExtent,
            listen: false,
          ),
        ).catchError((_) => ImagePreloadResult.failed),
      );
    }
  }

  void _onTransformed() {
    final scale = _transformationFor(_activePage).value.getMaxScaleOnAxis();
    if (scale >= ImageViewerPage.fullDecodeScale &&
        _fullDecode.add(_activePage)) {
      setState(() {});
    }
    final zoomed = _activeZoomed;
    if (zoomed != _activeZoomedSnapshot) {
      // Only rebuild when the physics actually flip (zoomed vs not); the
      // transformation listener fires every frame during a pinch, and a
      // setState per frame rebuilds the whole PageView (U3/R7).
      _activeZoomedSnapshot = zoomed;
      setState(() {});
    }
  }

  bool _activeZoomedSnapshot = false;

  void _setSystemChrome({required bool visible}) {
    unawaited(
      setSystemUiMode(
        visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      ),
    );
  }

  void _setChromeVisible(bool visible) {
    _chromeHideTimer?.cancel();
    _pointerChromeRevealed = false;
    if (viewerSessionChromeVisible == visible) {
      setState(() {});
      return;
    }
    viewerSessionChromeVisible = visible;
    _setSystemChrome(visible: visible);
    setState(() {});
  }

  void _toggleChrome() => _setChromeVisible(!_chromeVisible);

  void _handlePointerMoveOrEnter(PointerEvent event) {
    if (inputModalityForPointerKind(event.kind) != InputModality.pointer) {
      return;
    }
    final size = _stageSize();
    final padding = MediaQuery.paddingOf(context);
    final topHotzone = padding.top + kToolbarHeight + 24;
    final bottomHotzone = size.height - padding.bottom - 96;
    final dy = event.localPosition.dy;
    final inHotzone =
        dy <= topHotzone || dy >= bottomHotzone || _scrubberHovered;

    var changed = false;
    if (!_stageHovered) {
      _stageHovered = true;
      changed = true;
    }
    _chromeHotzoneHovered = inHotzone;
    if (!viewerSessionChromeVisible) {
      if (!_pointerChromeRevealed) {
        _pointerChromeRevealed = true;
        changed = true;
      }
      _chromeHideTimer?.cancel();
      if (!inHotzone) {
        _chromeHideTimer = Timer(const Duration(seconds: 2), () {
          if (!mounted || _chromeHotzoneHovered || viewerSessionChromeVisible) {
            return;
          }
          if (_pointerChromeRevealed) {
            setState(() => _pointerChromeRevealed = false);
          }
        });
      }
    }
    if (changed) setState(() {});
  }

  void _handlePointerExit(PointerExitEvent event) {
    _chromeHideTimer?.cancel();
    _scrubberHovered = false;
    _chromeHotzoneHovered = false;
    if (_stageHovered || _pointerChromeRevealed) {
      setState(() {
        _stageHovered = false;
        _pointerChromeRevealed = false;
      });
    }
  }

  void _onScrubberHoverChanged(int? page) {
    _scrubberHovered = page != null;
    if (_scrubberHovered) {
      _chromeHotzoneHovered = true;
      _chromeHideTimer?.cancel();
    } else {
      _chromeHotzoneHovered = false;
    }
    if (page != null) _prefetchScrubWindow(page);
  }

  Size _stageSize() {
    final box = _stageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) return box.size;
    return HomeShellChrome.contentSizeOf(context);
  }

  void _onZoomStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      final page = _zoomTargetPage;
      if (page != null) _targetZoomMatrices.remove(page);
    }
  }

  /// fit → 2.5 (at the tap focal) → fit. The cycle is a Matrix4 tween so
  /// the focal point stays pinned under the user's finger. Per design
  /// §2.3 the toggle threshold is 1.5: a double tap below it always zooms
  /// in (even from a slight pinch), at/above it snaps back to fit.
  void _onDoubleTap() {
    _targetZoomMatrices.remove(_activePage);
    final target = _transformationFor(_activePage);
    final zoomed = target.value.getMaxScaleOnAxis() >= 1.5;
    final focal = _doubleTapFocal ?? _stageSize().center(Offset.zero);
    _animateZoom(target, zoomed ? Matrix4.identity() : _focalZoom(focal, 2.5));
  }

  Matrix4 _focalZoom(Offset focal, double scale) => Matrix4.identity()
    ..translateByDouble(focal.dx, focal.dy, 0, 1)
    ..scaleByDouble(scale, scale, scale, 1)
    ..translateByDouble(-focal.dx, -focal.dy, 0, 1);

  void _stopZoomAnimation([int? page]) {
    if (page != null) _targetZoomMatrices.remove(page);
    if (page != null && _zoomTargetPage != page) return;
    _zoomController.stop();
    _zoomTarget = null;
    _zoomTargetPage = null;
    _zoomTween = null;
  }

  void _animateZoom(TransformationController target, Matrix4 end) {
    final duration = MotionTokens.resolve(context, MotionTokens.spatial);
    if (duration == Duration.zero) {
      _stopZoomAnimation();
      _targetZoomMatrices.remove(_activePage);
      target.value = end;
      return;
    }
    _zoomTarget = target;
    _zoomTargetPage = _activePage;
    _targetZoomMatrices[_activePage] = end;
    _zoomTween = Matrix4Tween(begin: target.value, end: end);
    _zoomController
      ..duration = duration
      ..forward(from: 0);
  }

  void _applyZoomFrame() {
    final tween = _zoomTween;
    final target = _zoomTarget;
    if (tween == null || target == null) return;
    target.value = tween.evaluate(_zoomCurve);
  }

  /// Explicit "fit to screen" reset — the bottom-bar button and the `0`
  /// key both land here (same result as the zoom cycle's fit leg).
  void _resetZoom() {
    _targetZoomMatrices.remove(_activePage);
    _animateZoom(_transformationFor(_activePage), Matrix4.identity());
  }

  /// Save the active page through the same controller as the detail
  /// badges: in-flight disables the button, done/error keep visible state.
  Future<void> _saveActivePage(IllustEntity entity) async {
    final download = ref.read(illustDownloadControllerProvider);
    try {
      await download.download(entity, _activePage);
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
  }

  Future<void> _share(IllustEntity entity) => shareIllust(context, ref, entity);

  Future<void> _downloadAll(IllustEntity entity) =>
      downloadAllIllustPages(context, ref, entity);

  /// Page counter → thumbnail jump sheet: same destination as a swipe,
  /// routed through PageController so `onPageChanged` still replaces the
  /// route. A jump across many pages does not animate the pages between.
  ///
  /// The jump waits until the sheet has finished closing: while the modal
  /// route is still on screen it blocks the viewer's semantics, and the
  /// counter's label changing under it trips the semantics flush
  /// (`node.built`).
  Future<void> _openPageSheet() async {
    final entity = widget.entity;
    TransitionRoute<int>? sheetRoute;
    final page = await showAppAdaptiveDialog<int>(
      context: context,
      maxWidth: 520,
      showDragHandle: true,
      builder: (sheetContext) {
        sheetRoute ??= ModalRoute.of(sheetContext) as TransitionRoute<int>?;
        return SafeArea(
          child: _PageJumpGrid(
            count: _pageCount,
            current: _activePage,
            // The square tier when the work is known; a cold deep link only
            // has the viewer URLs, decoded at the cell size.
            thumbnailFor: (page) =>
                entity?.squareUrlAt(page) ?? widget.urls[page],
            onSelected: (page) => Navigator.of(sheetContext).pop(page),
          ),
        );
      },
    );
    if (page == null) return;
    await sheetRoute?.completed;
    if (!mounted) return;
    _pageController.jumpToPage(page);
  }

  bool _isWideInfoLayout(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= AppBreakpoints.expanded;

  bool _wideInfoPanelOpen(BuildContext context) =>
      _infoPanelOpen && widget.entity != null && _isWideInfoLayout(context);

  void _openFromInfoPanel(Future<void> Function(BuildContext context) open) {
    final navContext = Navigator.of(context).context;
    final hasRouter = GoRouter.maybeOf(context) != null;
    Navigator.of(context).pop<void>();
    if (hasRouter) unawaited(open(navContext));
  }

  /// Info sheet — the viewer stays put; meta (title/author/date/id/pages)
  /// plus the same save-all / open-detail actions as the detail page.
  /// On wide layouts (`>= 840dp`), toggles the docked right panel instead.
  void _showInfo(IllustEntity entity) {
    if (_isWideInfoLayout(context)) {
      setState(() => _infoPanelOpen = !_infoPanelOpen);
      return;
    }
    final darkTheme = darkReplicaThemeOf(context);
    unawaited(
      showAppAdaptiveSideSheet<void>(
        context: context,
        width: 380,
        backgroundColor: darkTheme.colorScheme.surfaceContainerLow,
        builder: (sheetContext) {
          final l10n = context.l10n;
          // Same date treatment as the detail page's InfoBlock: the ISO
          // createDate goes through the locale format instead of leaking
          // the raw wire string into the sheet.
          final createDate = DateTime.tryParse(entity.createDate ?? '');
          final dateText = createDate == null
              ? null
              : AppFormat.date(context, createDate);
          return Theme(
            data: darkTheme,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!useWideOverlay(sheetContext))
                    Padding(
                      padding: const EdgeInsets.only(
                        top: FuncSpacing.md,
                        bottom: FuncSpacing.xs,
                      ),
                      child: Center(
                        child: Container(
                          width: 32,
                          height: 4,
                          decoration: BoxDecoration(
                            color: darkTheme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.4),
                            borderRadius: FuncShape.pill,
                          ),
                        ),
                      ),
                    ),
                  ListTile(
                    title: Text(entity.title),
                    subtitle: Text(
                      '${entity.user.name}'
                      '${dateText == null ? '' : ' · $dateText'}'
                      ' · #${entity.id} · '
                      '${l10n.illustPagesTotal(entity.pageCount)}',
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(AppIcons.download),
                    title: Text(l10n.downloadAll),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_downloadAll(entity));
                    },
                  ),
                  ListTile(
                    leading: const Icon(AppIcons.externalLink),
                    title: Text(l10n.viewerOpenDetail),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      // The viewer is opened from this work's detail page;
                      // closing it reveals the existing detail route below.
                      Navigator.of(context).pop();
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openContextMenu(TapUpDetails details, IllustPageSaveState? saveState) {
    final entity = widget.entity;
    final l10n = context.l10n;
    final zoomed = _activeZoomed;
    unawaited(
      showDisplayActions(
        context,
        position: details.globalPosition,
        kind: details.kind,
        onLongPress: entity != null ? () => _showInfo(entity) : _toggleChrome,
        actions: [
          if (entity != null)
            DisplayAction(
              icon: AppIcons.download,
              label: l10n.viewerSavePage,
              enabled:
                  saveState != IllustPageSaveState.downloading &&
                  saveState != IllustPageSaveState.exist,
              onSelected: () => unawaited(_saveActivePage(entity)),
            ),
          if (entity != null && _pageCount > 1)
            DisplayAction(
              icon: AppIcons.downloading,
              label: l10n.downloadAll,
              onSelected: () => unawaited(_downloadAll(entity)),
            ),
          if (entity != null) ...[
            if (isDesktopImageClipboardSupported)
              DisplayAction(
                icon: AppIcons.copy,
                label: l10n.copyOriginalImage,
                onSelected: () => unawaited(
                  copyIllustOriginalImageToClipboard(
                    context,
                    ProviderScope.containerOf(context),
                    entity,
                    pageIndex: _activePage,
                  ),
                ),
              ),
            DisplayAction(
              icon: AppIcons.share,
              label: l10n.share,
              onSelected: () => unawaited(_share(entity)),
            ),
            DisplayAction(
              icon: AppIcons.link,
              label: l10n.copyLink,
              onSelected: () => unawaited(
                copyToClipboard(
                  context,
                  'https://www.pixiv.net/artworks/${entity.id}',
                  message: l10n.linkCopied,
                ),
              ),
            ),
          ],
          DisplayAction(
            icon: zoomed ? AppIcons.fitScreen : AppIcons.zoomIn,
            label: zoomed ? l10n.viewerFitScreen : l10n.viewerZoomIn,
            onSelected: () {
              if (zoomed) {
                _resetZoom();
              } else {
                _animateZoom(
                  _transformationFor(_activePage),
                  _focalZoom(details.localPosition, 2.5),
                );
              }
            },
          ),
          DisplayAction(
            icon: UiIcons.arrowBack,
            label: MaterialLocalizations.of(context).backButtonTooltip,
            onSelected: _imperativePop,
          ),
        ],
      ),
    );
  }

  ValueNotifier<ImageLoadProgress> _progressFor(int page) => _progress
      .putIfAbsent(page, () => ValueNotifier(const ImageLoadProgress.idle()));

  TransformationController _transformationFor(int page) {
    return _transformations.putIfAbsent(page, TransformationController.new);
  }

  bool get _activeZoomed =>
      (_transformationFor(_activePage).value.getMaxScaleOnAxis()) >
      1.0 + precisionErrorTolerance;

  /// The stage is black whatever the app's theme: under a light one, a
  /// status view takes the dark theme to stay readable.
  static Widget _onStage(BuildContext context, Widget child) =>
      Theme.of(context).brightness == Brightness.dark
      ? child
      : Theme(data: darkReplicaThemeOf(context), child: child);

  @override
  Widget build(BuildContext context) {
    String text(String key) => l10nLookup(context.l10n, key);
    final entity = widget.entity;
    if (entity != null) _ensureDownloadListener();
    // The save action mirrors the detail-page badge semantics through the
    // same controller: in-flight disables the button, done/error keep
    // visible state.
    final saveState = entity == null
        ? null
        : ref
              .watch(illustDownloadControllerProvider)
              .stateFor(entity.id, _activePage);
    final wideInfoOpen = _wideInfoPanelOpen(context);
    // The fullscreen viewer deliberately keeps an opaque black canvas so
    // artwork and its white chrome match the replica surface.
    return PopScope<void>(
      // Close an open wide info panel first, then unzoom, before popping the
      // viewer route. Hidden chrome remains a view state, not a back gate.
      canPop: !wideInfoOpen && !_activeZoomed,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !mounted) return;
        if (_wideInfoPanelOpen(context)) {
          setState(() => _infoPanelOpen = false);
          return;
        }
        // System back while zoomed: reset to fit and stay on the route.
        _resetZoom();
      },
      child: CallbackShortcuts(
        bindings: _shortcuts(),
        child: Focus(
          autofocus: true,
          child: _ExitSlide(
            // A drag-to-dismiss on the entry page shrinks the image back
            // into the detail page; from any other page the stage leaves
            // downward. Back and the back gesture fade the viewer out.
            slidesOut: () =>
                _dismissedByDrag &&
                widget.heroTagForPage?.call(_activePage) == null,
            child: DragToDismiss(
              enabled: !_activeZoomed,
              allowPointer: (event) => event.pointer != _scrubPointer,
              onDismissed: () {
                _dismissedByDrag = true;
                Navigator.of(context).pop<void>();
              },
              // The stage is always black; pin light bar icons while the
              // viewer is mounted so the clock stays readable after exiting
              // immersive mode (the AnnotatedRegion restores the ambient
              // style on pop).
              child: FuncSystemBars(
                background: Brightness.dark,
                child: Scaffold(
                  // primary: false — the media fills the whole screen edge to
                  // edge; each chrome bar SafeAreas its own controls.
                  primary: false,
                  backgroundColor: Colors.black,
                  body: Row(
                    children: [
                      Expanded(
                        child: MouseRegion(
                          key: _stageKey,
                          onEnter: _handlePointerMoveOrEnter,
                          onHover: _handlePointerMoveOrEnter,
                          onExit: _handlePointerExit,
                          child: Stack(
                            children: [
                              Positioned.fill(
                                // A status has nothing to zoom and keeps its exits:
                                // outside the stage's taps, its retry answers at
                                // once instead of after the double-tap timeout.
                                child: _pageCount == 0
                                    ? widget.loading
                                          ? const FeedLoading()
                                          : widget.failure != null
                                          ? _onStage(context, widget.failure!)
                                          : Center(
                                              child: Text(
                                                text('viewerNoImages'),
                                                style: TextStyle(
                                                  color: FuncTokens.white,
                                                ),
                                              ),
                                            )
                                    : GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        // Tap toggles chrome; double-tap runs the
                                        // zoom cycle. One detector registers both
                                        // so the framework arena does the
                                        // ~kDoubleTapTimeout disambiguation (risks
                                        // R1 — no custom timer).
                                        onTap: _toggleChrome,
                                        onDoubleTapDown: (details) =>
                                            _doubleTapFocal =
                                                details.localPosition,
                                        onDoubleTap: _onDoubleTap,
                                        onSecondaryTapUp: (details) =>
                                            _openContextMenu(
                                              details,
                                              saveState,
                                            ),
                                        child:
                                            // The paging slop: a drag leaning towards
                                            // vertical dismisses instead of paging.
                                            PagingSlop(
                                              child: PageView.builder(
                                                controller: _pageController,
                                                physics: _activeZoomed
                                                    ? const NeverScrollableScrollPhysics()
                                                    : const PageSnapPhysics(),
                                                itemCount: _pageCount,
                                                itemBuilder: (context, page) =>
                                                    PagingSlopPage(
                                                      // Unzoomed, the image's pan must
                                                      // not tie with the pager; zoomed,
                                                      // the pager is off.
                                                      restore: _isZoomed(page),
                                                      child: _buildPage(
                                                        context,
                                                        page,
                                                      ),
                                                    ),
                                              ),
                                            ),
                                      ),
                              ),
                              if (_pageCount > 1 &&
                                  (InputModalityScope.maybeOf(context) ??
                                          defaultInputModalityFor(
                                            Theme.of(context).platform,
                                          )) ==
                                      InputModality.pointer) ...[
                                _ViewerPageNavButton(
                                  key: const Key('viewer-prev-page'),
                                  visible: _chromeVisible && _activePage > 0,
                                  alignment: AlignmentDirectional.centerStart,
                                  icon: UiIcons.chevronLeft,
                                  tooltip: MaterialLocalizations.of(
                                    context,
                                  ).previousPageTooltip,
                                  onPressed: _pageBackward,
                                ),
                                _ViewerPageNavButton(
                                  key: const Key('viewer-next-page'),
                                  visible:
                                      _chromeVisible &&
                                      _activePage + 1 < _pageCount,
                                  alignment: AlignmentDirectional.centerEnd,
                                  icon: UiIcons.chevronRight,
                                  tooltip: MaterialLocalizations.of(
                                    context,
                                  ).nextPageTooltip,
                                  onPressed: _pageForward,
                                ),
                              ],
                              _ChromeEdgeBar(
                                visible: _chromeVisible,
                                edge: _ChromeEdge.top,
                                child: _buildTopBar(context),
                              ),
                              _ChromeEdgeBar(
                                visible: _chromeVisible,
                                edge: _ChromeEdge.bottom,
                                child: _buildBottomBar(context, saveState),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_isWideInfoLayout(context) && entity != null)
                        _ViewerInfoPanelSlot(
                          open: _infoPanelOpen,
                          child: _ViewerInfoPanel(
                            entity: entity,
                            onClose: () =>
                                setState(() => _infoPanelOpen = false),
                            onSaveAll: () => unawaited(_downloadAll(entity)),
                            onOpenDetail: () =>
                                Navigator.of(context).pop<void>(),
                            onOpenAuthor: () => _openFromInfoPanel(
                              (ctx) => openUser(ctx, entity.user.id),
                            ),
                            onOpenTag: (tag) => _openFromInfoPanel(
                              (ctx) => openTagSearch(ctx, tag),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Keyboard parity (desktop + hardware keyboards on mobile): every
  /// toolbar/gesture action has a key. Esc/Backspace pops imperatively —
  /// same contract as the back button and drag-dismiss (W1 split).
  Map<ShortcutActivator, VoidCallback> _shortcuts() => {
    const SingleActivator(LogicalKeyboardKey.arrowLeft): _pageBackward,
    const SingleActivator(LogicalKeyboardKey.keyK): _pageBackward,
    const SingleActivator(LogicalKeyboardKey.arrowRight): _pageForward,
    const SingleActivator(LogicalKeyboardKey.keyJ): _pageForward,
    const SingleActivator(LogicalKeyboardKey.equal): _zoomIn,
    const SingleActivator(LogicalKeyboardKey.add): _zoomIn,
    const SingleActivator(LogicalKeyboardKey.numpadAdd): _zoomIn,
    const SingleActivator(LogicalKeyboardKey.minus): _zoomOut,
    const SingleActivator(LogicalKeyboardKey.numpadSubtract): _zoomOut,
    const SingleActivator(LogicalKeyboardKey.digit0): _resetZoom,
    const SingleActivator(LogicalKeyboardKey.numpad0): _resetZoom,
    const SingleActivator(LogicalKeyboardKey.keyF): _toggleChrome,
    const SingleActivator(LogicalKeyboardKey.escape): _handleBackShortcut,
    const SingleActivator(LogicalKeyboardKey.backspace): _handleBackShortcut,
    const SingleActivator(LogicalKeyboardKey.keyS): _saveActivePageIfAny,
    const SingleActivator(LogicalKeyboardKey.keyI): _showInfoIfAny,
  };

  void _pageForward() {
    if (_activePage + 1 >= _pageCount) return;
    turnPage(context, _pageController, _activePage + 1);
  }

  void _pageBackward() {
    if (_activePage <= 0) return;
    turnPage(context, _pageController, _activePage - 1);
  }

  void _zoomIn() => _zoomBy(1.25);

  void _zoomOut() => _zoomBy(1 / 1.25);

  /// Multiplicative zoom centered on the viewport — keyboard zooms have no
  /// pointer focal, so the screen center is the honest anchor.
  void _zoomBy(double factor) =>
      _zoomAt(_stageSize().center(Offset.zero), factor);

  /// Keys and the wheel stay inside a pinch's bounds, accumulating successive
  /// wheel ticks onto the in-flight target matrix.
  void _zoomAt(Offset focal, double factor) {
    final target = _transformationFor(_activePage);
    final base = _targetZoomMatrices[_activePage] ?? target.value;
    final scale = base.getMaxScaleOnAxis();
    final next = (scale * factor).clamp(
      ImageViewerPage.minScale,
      ImageViewerPage.maxScale,
    );
    if ((factor < 1 && scale <= 1.001) || (next >= 0.94 && next <= 1.06)) {
      _animateZoom(target, Matrix4.identity());
      return;
    }
    final end = _focalZoom(focal, next / scale)..multiply(base);
    final size = _stageSize();
    if (next > 1.0) {
      end.setEntry(0, 3, end.entry(0, 3).clamp(size.width * (1 - next), 0.0));
      end.setEntry(1, 3, end.entry(1, 3).clamp(size.height * (1 - next), 0.0));
    } else {
      end.setEntry(0, 3, size.width * (1 - next) / 2);
      end.setEntry(1, 3, size.height * (1 - next) / 2);
    }
    _animateZoom(target, end);
  }

  void _handleBackShortcut() {
    if (_wideInfoPanelOpen(context)) {
      setState(() => _infoPanelOpen = false);
      return;
    }
    _imperativePop();
  }

  /// Imperative pop — explicit exits (back button, Esc/Backspace) always
  /// leave. PopScope's `canPop` is only re-registered on rebuild, so when a
  /// zoom is still active we snap the transform back to fit and pop on the
  /// next frame — one frame's delay beats re-arming the gate machinery.
  void _imperativePop() {
    _targetZoomMatrices.clear();
    if (!_activeZoomed) {
      Navigator.of(context).pop<void>();
      return;
    }
    _transformationFor(_activePage).value = Matrix4.identity();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop<void>();
    });
  }

  void _saveActivePageIfAny() {
    final entity = widget.entity;
    if (entity == null || _pageCount == 0) return;
    unawaited(_saveActivePage(entity));
  }

  void _showInfoIfAny() {
    final entity = widget.entity;
    if (entity == null || _pageCount == 0) return;
    _showInfo(entity);
  }

  /// Pointer-signal zoom: the wheel scales the active page around the
  /// pointer position (same semantics as the pinch), Shift+wheel turns the
  /// page instead. This Listener sits deeper than the PageView's own
  /// scrollable, and the pointer-signal resolver is first-registered
  /// first-served — a wheel tick never reaches the pager.
  void _onPagePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _pageCount == 0) return;
    // Route through the pointer-signal resolver: this listener sits deeper in
    // the hit-test path than the pager's Scrollable, so registering here wins
    // the event outright. Acting synchronously would still let the Scrollable
    // register afterwards and fire its own shift+wheel axis-flip scroll, which
    // would goIdle() the page animation we just started.
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      _handlePagePointerSignal,
    );
  }

  void _handlePagePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !mounted || _pageCount == 0) return;
    final dy = event.scrollDelta.dy;
    if (_isShiftPressed()) {
      final delta = dy != 0 ? dy : event.scrollDelta.dx;
      if (delta > 0) {
        _pageForward();
      } else if (delta < 0) {
        _pageBackward();
      }
      return;
    }
    if (dy == 0) return;
    _zoomAt(event.localPosition, dy < 0 ? 1.2 : 1 / 1.2);
  }

  bool _isShiftPressed() => HardwareKeyboard.instance.logicalKeysPressed.any(
    (key) =>
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight,
  );

  Widget _buildPage(BuildContext context, int page) {
    return Builder(
      builder: (context) {
        final heroTag = widget.heroTagForPage?.call(page);
        final decodeWidth = _fullDecode.contains(page)
            ? null
            : ImageViewerPage.previewDecodeWidth(context);
        // Every page hands over between its decodes: the preview paints
        // while the whole file decodes, with or without a Hero.
        final transitionKey = heroTag ?? (#viewerPage, widget.urls[page]);
        // Screen readers get a per-page image node ("第 n 页，共 N 页") —
        // without it the media surface announces nothing (PRD R4 a11y).
        final viewer = Semantics(
          image: true,
          label: context.l10n.viewerPageLabel(page + 1, _pageCount),
          child: Listener(
            onPointerSignal: _onPagePointerSignal,
            child: InteractiveViewer(
              key: ValueKey('viewer-page-$page'),
              transformationController: _transformationFor(page),
              minScale: ImageViewerPage.minScale,
              maxScale: ImageViewerPage.maxScale,
              panEnabled: _isZoomed(page),
              onInteractionStart: (_) => _stopZoomAnimation(page),
              // Tight constraints (U3): Center alone gives loose
              // constraints, so RenderImage laid out at its intrinsic
              // size (original pixels / DPR) and BoxFit.contain had
              // nothing to fill. Expanding forces the image to fill
              // the viewport, giving the zoom a real target.
              child: SizedBox.expand(
                // transitionKey hooks the viewer into the detail page's
                // quality history — the last decoded tier paints as the
                // placeholder while the requested tier resolves, so a
                // large->original hand-off never shows a grey box.
                child: PixivImage(
                  url: widget.urls[page],
                  fit: BoxFit.contain,
                  memCacheWidth: decodeWidth,
                  transitionKey: transitionKey,
                  tierKey: widget.tierKeyForPage?.call(page),
                  tier: widget.tier,
                  // The stage is already black — the default container
                  // tier would flash a grey box under the artwork.
                  placeholderColor: FuncTokens.transparent,
                  progress: _progressFor(page),
                ),
              ),
            ),
          ),
        );
        // Outside the Hero and the zoom, so the ring neither flies nor
        // scales with the artwork.
        final progress = Positioned.fill(
          child: ImageLoadProgressOverlay(progress: _progressFor(page)),
        );
        if (heroTag == null) {
          return Stack(fit: StackFit.expand, children: [viewer, progress]);
        }
        final heroCurve = illustHeroCurve(context);
        final hero = Hero(
          tag: heroTag,
          curve: heroCurve,
          reverseCurve: heroCurve,
          createRectTween: illustHeroRectTween,
          flightShuttleBuilder: illustHeroFlightShuttleBuilder,
          child: IllustHeroFlightChild(
            containsImage: true,
            // The black stage runs under the status bar.
            edgeToEdge: true,
            // The return shuttle paints the exact provider the
            // viewer is showing (same URL + same decode width =>
            // same decoded cache entry => identical pixels).
            // Painting the fixed detail tier here downgraded an
            // already-loaded original to large at flight start —
            // the flash seen when popping back to the detail page.
            popChild: SizedBox.expand(
              child: PixivImage(
                url: widget.urls[page],
                fit: BoxFit.contain,
                memCacheWidth: decodeWidth,
                transitionKey: heroTag,
                tierKey: widget.tierKeyForPage?.call(page),
                tier: widget.tier,
                placeholderColor: FuncTokens.transparent,
              ),
            ),
            child: viewer,
          ),
        );
        return Stack(fit: StackFit.expand, children: [hero, progress]);
      },
    );
  }

  /// Top chrome: back affordance + the `n / total` counter, the viewer's
  /// only page counter. Tapping it opens the thumbnail jump sheet.
  Widget _buildTopBar(BuildContext context) {
    final leadingInset =
        DesktopChromeMetrics.maybeOf(context)?.leadingInset ?? 0;
    return Material(
      color: FuncTokens.transparent,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: leadingInset > 0 ? 0 : FuncSpacing.sm,
            end: FuncSpacing.sm,
          ),
          child: Row(
            children: [
              if (leadingInset > 0) SizedBox(width: leadingInset),
              // Imperative pop: explicit exits never route through the
              // system-back intercept chain (W1 split).
              BackButton(onPressed: _imperativePop),
              const Spacer(),
              // Empty state honesty: no misleading "1 / 0" counter.
              if (_pageCount > 0)
                TextButton(
                  key: const Key('viewer-page-counter'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FuncSpacing.sm,
                    ),
                    minimumSize: const Size.square(kMinInteractiveDimension),
                  ),
                  onPressed: _openPageSheet,
                  // Inside the button, so its one node carries both the
                  // count and what tapping it does. The detail page's pill,
                  // so the position reads the same on both sides of the Hero.
                  child: Tooltip(
                    message: context.l10n.viewerJumpToPage,
                    child: PageCountPill(page: _activePage, count: _pageCount),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Bottom chrome: fit / save / share / info at the end. A single tap on
  /// the artwork (or F) hides the chrome, so there is no fullscreen button.
  /// Entity-bound actions render only when the route resolved an entity
  /// (deep-link snapshot case skips them).
  Widget _buildBottomBar(BuildContext context, IllustPageSaveState? saveState) {
    final entity = widget.entity;
    final l10n = context.l10n;
    final hasPages = _pageCount > 0;
    final modality =
        InputModalityScope.maybeOf(context) ??
        defaultInputModalityFor(Theme.of(context).platform);
    final showScrubber =
        _pageCount >= 4 ||
        (modality == InputModality.pointer && _pageCount >= 2);
    return Material(
      color: FuncTokens.transparent,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showScrubber)
              Listener(
                onPointerDown: (event) => _scrubPointer = event.pointer,
                child: _PageScrubber(
                  key: const Key('viewer-page-scrubber'),
                  count: _pageCount,
                  current: _activePage,
                  value: _scrubPage ?? _activePage,
                  dragging: _scrubPage != null,
                  onChanged: _onScrubChanged,
                  onChangeEnd: _onScrubEnd,
                  onHoverPageChanged: _onScrubberHoverChanged,
                  pageLabel: (page) =>
                      context.l10n.viewerPageLabel(page + 1, _pageCount),
                  thumbnailUrl: (page) => widget.entity?.squareUrlAt(page),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.sm),
              child: Row(
                children: [
                  const Spacer(),
                  IconButton(
                    tooltip: l10n.viewerFitScreen,
                    onPressed: hasPages ? _resetZoom : null,
                    icon: const Icon(AppIcons.fitScreen),
                  ),
                  if (entity != null) ...[
                    IconButton(
                      tooltip: l10n.viewerSavePage,
                      onPressed: !hasPages
                          ? null
                          : switch (saveState) {
                              IllustPageSaveState.downloading ||
                              IllustPageSaveState.exist => null,
                              _ => () => unawaited(_saveActivePage(entity)),
                            },
                      icon: switch (saveState) {
                        IllustPageSaveState.downloading => const AppSpinner(
                          size: 20,
                          strokeWidth: 2,
                        ),
                        IllustPageSaveState.exist => const Icon(
                          UiIcons.checkCircle,
                        ),
                        IllustPageSaveState.error => const Icon(
                          UiIcons.errorOutline,
                        ),
                        _ => const Icon(AppIcons.download),
                      },
                    ),
                    IconButton(
                      tooltip: l10n.cardActionShare,
                      onPressed: hasPages
                          ? () => unawaited(_share(entity))
                          : null,
                      icon: const Icon(AppIcons.share),
                    ),
                    IconButton(
                      tooltip: l10n.viewerInfo,
                      onPressed: hasPages ? () => _showInfo(entity) : null,
                      icon: Icon(
                        _wideInfoPanelOpen(context)
                            ? AppIcons.infoFilled
                            : AppIcons.info,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isZoomed(int page) =>
      _transformationFor(page).value.getMaxScaleOnAxis() >
      1.0 + precisionErrorTolerance;
}

class _ViewerInfoPanelSlot extends StatefulWidget {
  const _ViewerInfoPanelSlot({required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  State<_ViewerInfoPanelSlot> createState() => _ViewerInfoPanelSlotState();
}

class _ViewerInfoPanelSlotState extends State<_ViewerInfoPanelSlot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curve;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, value: widget.open ? 1 : 0)
      ..addStatusListener(_onStatus);
    _curve = CurvedAnimation(
      parent: _controller,
      curve: MotionTokens.chromeCurve,
      reverseCurve: MotionTokens.chromeCurve.flipped,
    );
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = MotionTokens.resolve(context, MotionTokens.chrome);
    _controller.duration = duration;
    _controller.reverseDuration = duration;
    if (duration == Duration.zero) {
      _controller.value = widget.open ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(covariant _ViewerInfoPanelSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open == widget.open) return;
    final duration = MotionTokens.resolve(context, MotionTokens.chrome);
    _controller.duration = duration;
    _controller.reverseDuration = duration;
    if (duration == Duration.zero) {
      _controller.value = widget.open ? 1 : 0;
      return;
    }
    if (widget.open) {
      unawaited(_controller.forward());
    } else {
      unawaited(_controller.reverse());
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.open && _controller.isDismissed) {
      return const SizedBox.shrink();
    }
    return ExcludeSemantics(
      excluding: !widget.open,
      child: ExcludeFocus(
        excluding: !widget.open,
        child: IgnorePointer(
          ignoring: !widget.open,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _curve,
              builder: (context, child) {
                final t = _curve.value.clamp(0.0, 1.0);
                return Align(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: t,
                  child: Opacity(
                    opacity: t,
                    alwaysIncludeSemantics: true,
                    child: child,
                  ),
                );
              },
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
