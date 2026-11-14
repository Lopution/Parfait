import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/clipboard.dart';
import '../../../app/format/app_format.dart';
import '../../../app/layout/input_modality.dart';
import '../../../app/motion/drag_to_dismiss.dart';
import '../../../app/haptics/app_haptics.dart';
import '../../../app/motion/app_overlays.dart';
import '../../../app/motion/motion_tokens.dart';
import '../../../app/navigation/home_shell_metrics.dart';
import '../../../app/navigation/route_animation.dart';
import '../../../app/navigation/routes.dart';
import '../../../app/motion/hero_transition.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/scroll_behavior.dart';
import '../../../app/widgets/app_slider.dart';
import '../../../app/widgets/display_actions.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart'
    show DownloadEvent, DownloadGroupSubmission;
import '../../../core/illust/illust_download_controller.dart';
import '../../../core/share/share_service.dart';
import '../../../core/image/image_demand.dart';
import '../../../core/image/image_worker_providers.dart';
import '../../../app/system_ui.dart';
import '../../../app/theme/func_tokens.dart';
import '../../../app/theme/replica_theme.dart';
import '../../../l10n/lookup.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/artwork_controls.dart';
import '../../../app/widgets/entity_row.dart' show EntityBadge;
import '../../../app/widgets/feed/feed_states.dart' show FeedLoading;
import '../../../app/widgets/errors/error_details.dart';
import '../../../l10n/context.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../detail/widgets/detail_page_counter.dart' show PageCountPill;
part 'image_viewer_chrome.dart';

/// Whether the viewer chrome (top bar + bottom bar) is visible. This is
/// session-level state (revision ①): it deliberately survives page turns,
/// keyboard turns, page-sheet jumps and `replaceImageViewerPage` route
/// swaps — the user asked for an immersive view and it stays immersive
/// until they ask otherwise. Per-page state (zoom/pan) resets normally.
bool _viewerSessionChromeVisible = true;

/// A fresh viewer session opens with the chrome visible (PRD R4's
/// 「默认可见」; design §2.3 scopes the holder to the viewer entry).
/// `openImageViewer` is the session entry — in-session page swaps go
/// through `replaceImageViewerPage` and must not reset this.
void beginImageViewerSession() {
  _viewerSessionChromeVisible = true;
}

/// Test hook: resets the session-level viewer state so widget tests are
/// independent of each other's chrome toggles.
@visibleForTesting
void debugResetViewerSession() {
  _viewerSessionChromeVisible = true;
}

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
      PixivImage.decodeWidthFor(
        HomeShellChrome.contentSizeOf(context).width * previewScale,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      );

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
  Tween<Matrix4>? _zoomTween;
  late final CurvedAnimation _zoomCurve;

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
  Timer? _chromeHideTimer;

  int get _pageCount => _pagesOf(widget);

  static int _pagesOf(ImageViewerPage viewer) =>
      viewer.loading && viewer.initialPage >= viewer.urls.length
      ? 0
      : viewer.urls.length;

  bool get _chromeVisible =>
      _viewerSessionChromeVisible || _pointerChromeRevealed;

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
      ..addListener(_applyZoomFrame);
    _zoomCurve = CurvedAnimation(
      parent: _zoomController,
      curve: MotionTokens.spatialCurve,
    );
    _pageController.addListener(_onPageChanged);
    _transformationFor(_activePage).addListener(_onTransformed);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _prefetchNeighbours(_activePage),
    );
    if (!_viewerSessionChromeVisible) _setSystemChrome(visible: false);
  }

  @override
  void didUpdateWidget(covariant ImageViewerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The pages arrived: the pager was never built, so it opens on the
    // page asked for instead of the one initState clamped to.
    if (_pagesOf(oldWidget) > 0 || _pageCount == 0) return;
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
    if (!_viewerSessionChromeVisible) _setSystemChrome(visible: true);
    super.dispose();
  }

  void _onPageChanged() {
    final page = _pageController.page?.round() ?? _activePage;
    if (page != _activePage) {
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
    if (_viewerSessionChromeVisible == visible) {
      setState(() {});
      return;
    }
    _viewerSessionChromeVisible = visible;
    _setSystemChrome(visible: visible);
    setState(() {});
  }

  void _toggleChrome() => _setChromeVisible(!_chromeVisible);

  void _handlePointerMoveOrEnter(PointerEvent event) {
    if (inputModalityForPointerKind(event.kind) != InputModality.pointer) {
      return;
    }
    final size = context.size ?? MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final topHotzone = padding.top + kToolbarHeight + 24;
    final bottomHotzone = size.height - padding.bottom - 96;
    final dy = event.localPosition.dy;
    final inHotzone = dy <= topHotzone || dy >= bottomHotzone;

    var changed = false;
    if (!_stageHovered) {
      _stageHovered = true;
      changed = true;
    }
    _chromeHotzoneHovered = inHotzone;
    if (!_viewerSessionChromeVisible) {
      if (!_pointerChromeRevealed) {
        _pointerChromeRevealed = true;
        changed = true;
      }
      _chromeHideTimer?.cancel();
      if (!inHotzone) {
        _chromeHideTimer = Timer(const Duration(seconds: 2), () {
          if (!mounted ||
              _chromeHotzoneHovered ||
              _viewerSessionChromeVisible) {
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
    _chromeHotzoneHovered = false;
    if (_stageHovered || _pointerChromeRevealed) {
      setState(() {
        _stageHovered = false;
        _pointerChromeRevealed = false;
      });
    }
  }

  /// fit → 2.5 (at the tap focal) → fit. The cycle is a Matrix4 tween so
  /// the focal point stays pinned under the user's finger. Per design
  /// §2.3 the toggle threshold is 1.5: a double tap below it always zooms
  /// in (even from a slight pinch), at/above it snaps back to fit.
  void _onDoubleTap() {
    final target = _transformationFor(_activePage);
    final zoomed = target.value.getMaxScaleOnAxis() >= 1.5;
    final focal =
        _doubleTapFocal ?? MediaQuery.sizeOf(context).center(Offset.zero);
    _animateZoom(target, zoomed ? Matrix4.identity() : _focalZoom(focal, 2.5));
  }

  Matrix4 _focalZoom(Offset focal, double scale) => Matrix4.identity()
    ..translateByDouble(focal.dx, focal.dy, 0, 1)
    ..scaleByDouble(scale, scale, scale, 1)
    ..translateByDouble(-focal.dx, -focal.dy, 0, 1);

  void _animateZoom(TransformationController target, Matrix4 end) {
    _zoomTarget = target;
    _zoomTween = Matrix4Tween(begin: target.value, end: end);
    _zoomController
      ..duration = MotionTokens.resolve(context, MotionTokens.spatial)
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
  void _resetZoom() =>
      _animateZoom(_transformationFor(_activePage), Matrix4.identity());

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

  Future<void> _share(IllustEntity entity) async {
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
    if (outcome == ShareOutcome.copiedToClipboard && mounted) {
      showAppSnackBar(context, context.l10n.linkCopied);
    }
  }

  Future<void> _downloadAll(IllustEntity entity) async {
    final l10n = context.l10n;
    late final DownloadGroupSubmission submission;
    try {
      submission = await ref
          .read(illustDownloadControllerProvider)
          .downloadAll(entity);
    } catch (error) {
      if (!mounted) return;
      AppHaptics.error();
      showErrorSnackBar(
        context,
        action: l10n.downloadSubmissionFailed,
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

  /// Info sheet — the viewer stays put; meta (title/author/date/id/pages)
  /// plus the same save-all / open-detail actions as the detail page.
  void _showInfo(IllustEntity entity) {
    unawaited(
      showAppAdaptiveSideSheet<void>(
        context: context,
        width: 380,
        showDragHandle: true,
        builder: (sheetContext) {
          final l10n = context.l10n;
          // Same date treatment as the detail page's InfoBlock: the ISO
          // createDate goes through the locale format instead of leaking
          // the raw wire string into the sheet.
          final createDate = DateTime.tryParse(entity.createDate ?? '');
          final dateText = createDate == null
              ? null
              : AppFormat.date(context, createDate);
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                  leading: const Icon(Icons.download_outlined),
                  title: Text(l10n.downloadAll),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_downloadAll(entity));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.open_in_new),
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
              icon: Icons.download_outlined,
              label: l10n.viewerSavePage,
              enabled:
                  saveState != IllustPageSaveState.downloading &&
                  saveState != IllustPageSaveState.exist,
              onSelected: () => unawaited(_saveActivePage(entity)),
            ),
          if (entity != null && _pageCount > 1)
            DisplayAction(
              icon: Icons.download_for_offline_outlined,
              label: l10n.downloadAll,
              onSelected: () => unawaited(_downloadAll(entity)),
            ),
          if (entity != null) ...[
            DisplayAction(
              icon: Icons.share_outlined,
              label: l10n.share,
              onSelected: () => unawaited(_share(entity)),
            ),
            DisplayAction(
              icon: Icons.link_outlined,
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
            icon: zoomed ? Icons.fit_screen : Icons.zoom_in,
            label: zoomed ? l10n.viewerFitScreen : '100%',
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
            icon: Icons.arrow_back,
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
      : Theme(data: replicaTheme(Brightness.dark), child: child);

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
    // The fullscreen viewer deliberately keeps an opaque black canvas so
    // artwork and its white chrome match the replica surface.
    return PopScope<void>(
      // canPop carries only the zoom leg (revision ②): hidden chrome is a
      // view state, not a gate — with chrome hidden the system back leaves
      // the route directly. Sheets/menus pushed on top still intercept back
      // themselves, and explicit exits pop imperatively below.
      canPop: !_activeZoomed,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !mounted) return;
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
                  body: MouseRegion(
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
                                      _doubleTapFocal = details.localPosition,
                                  onDoubleTap: _onDoubleTap,
                                  onSecondaryTapUp: (details) =>
                                      _openContextMenu(details, saveState),
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
                            visible:
                                (_stageHovered || _chromeVisible) &&
                                _activePage > 0,
                            alignment: AlignmentDirectional.centerStart,
                            icon: Icons.chevron_left,
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).previousPageTooltip,
                            onPressed: _pageBackward,
                          ),
                          _ViewerPageNavButton(
                            key: const Key('viewer-next-page'),
                            visible:
                                (_stageHovered || _chromeVisible) &&
                                _activePage + 1 < _pageCount,
                            alignment: AlignmentDirectional.centerEnd,
                            icon: Icons.chevron_right,
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
    const SingleActivator(LogicalKeyboardKey.escape): _imperativePop,
    const SingleActivator(LogicalKeyboardKey.backspace): _imperativePop,
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
  void _zoomBy(double factor) => _zoomAt(
    HomeShellChrome.contentSizeOf(context).center(Offset.zero),
    factor,
  );

  /// Keys and the wheel stay inside a pinch's bounds.
  void _zoomAt(Offset focal, double factor) {
    final target = _transformationFor(_activePage);
    final scale = target.value.getMaxScaleOnAxis();
    final next = (scale * factor).clamp(
      ImageViewerPage.minScale,
      ImageViewerPage.maxScale,
    );
    _animateZoom(
      target,
      _focalZoom(focal, next / scale)..multiply(target.value),
    );
  }

  /// Imperative pop — explicit exits (back button, Esc/Backspace) always
  /// leave. PopScope's `canPop` is only re-registered on rebuild, so when a
  /// zoom is still active we snap the transform back to fit and pop on the
  /// next frame — one frame's delay beats re-arming the gate machinery.
  void _imperativePop() {
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
    if (_isShiftPressed()) {
      if (event.scrollDelta.dy > 0) {
        _pageForward();
      } else if (event.scrollDelta.dy < 0) {
        _pageBackward();
      }
      return;
    }
    _zoomAt(event.localPosition, event.scrollDelta.dy < 0 ? 1.2 : 1 / 1.2);
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
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
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
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pageCount >= 4)
              Listener(
                onPointerDown: (event) => _scrubPointer = event.pointer,
                child: _PageScrubber(
                  key: const Key('viewer-page-scrubber'),
                  count: _pageCount,
                  current: _activePage,
                  value: _scrubPage ?? _activePage,
                  onChanged: _onScrubChanged,
                  onChangeEnd: _onScrubEnd,
                  pageLabel: (page) =>
                      context.l10n.viewerPageLabel(page + 1, _pageCount),
                  thumbnailUrl: (page) => widget.entity?.squareUrlAt(page),
                ),
              ),
            Row(
              children: [
                const Spacer(),
                IconButton(
                  tooltip: l10n.viewerFitScreen,
                  onPressed: hasPages ? _resetZoom : null,
                  icon: const Icon(Icons.fit_screen),
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
                      IllustPageSaveState.downloading => const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      IllustPageSaveState.exist => const Icon(
                        Icons.check_circle,
                      ),
                      IllustPageSaveState.error => const Icon(
                        Icons.error_outline,
                      ),
                      _ => const Icon(Icons.download_outlined),
                    },
                  ),
                  IconButton(
                    tooltip: l10n.cardActionShare,
                    onPressed: hasPages
                        ? () => unawaited(_share(entity))
                        : null,
                    icon: const Icon(Icons.share_outlined),
                  ),
                  IconButton(
                    tooltip: l10n.viewerInfo,
                    onPressed: hasPages ? () => _showInfo(entity) : null,
                    icon: const Icon(Icons.info_outline),
                  ),
                ],
              ],
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
