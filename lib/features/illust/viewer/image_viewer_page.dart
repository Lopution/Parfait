import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/format/app_format.dart';
import '../../../app/motion/drag_to_dismiss.dart';
import '../../../app/haptics/app_haptics.dart';
import '../../../app/motion/app_overlays.dart';
import '../../../app/motion/motion_tokens.dart';
import '../../../app/navigation/routes.dart';
import '../../../app/motion/hero_transition.dart';
import '../../../app/pixiv_image.dart';
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
import '../../../l10n/lookup.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/artwork_controls.dart';
import '../../../app/widgets/entity_row.dart' show EntityBadge;
import '../../../app/widgets/errors/error_details.dart';
import '../../../l10n/context.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../detail/widgets/detail_page_counter.dart' show PageCountPill;

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

  /// Zoom bounds (PRD R3: strictly 0.9–6.0).
  static const double minScale = 0.9;
  static const double maxScale = 6.0;

  @override
  ConsumerState<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends ConsumerState<ImageViewerPage>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController;
  late final AnimationController _zoomController;
  final _transformations = <int, TransformationController>{};

  /// Per-page download progress for the ring over the page.
  final _progress = <int, ValueNotifier<ImageLoadProgress>>{};
  int _activePage = 0;

  /// The page controller currently being zoom-animated and the tween
  /// driving it (focal zoom → Matrix4, not a scalar scale).
  TransformationController? _zoomTarget;
  Tween<Matrix4>? _zoomTween;
  late final Animation<double> _zoomCurve;

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

  int get _pageCount => widget.urls.length;

  bool get _chromeVisible => _viewerSessionChromeVisible;

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
      curve: MotionTokens.fastCurve,
    );
    _pageController.addListener(_onPageChanged);
    _transformationFor(_activePage).addListener(_onTransformed);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _prefetchNeighbours(_activePage),
    );
    if (!_viewerSessionChromeVisible) _setSystemChrome(visible: false);
  }

  /// The download manager publishes task changes on a stream rather than
  /// through listenable state — without this the save button's
  /// `stateFor` badge (spinner/check/error) would only refresh when some
  /// unrelated rebuild happens. Only installed once an entity exists —
  /// the badge it feeds never renders without one (this also keeps the
  /// viewer usable in ProviderScope-less harnesses, where no entity can
  /// ever arrive).
  void _ensureDownloadListener() {
    _downloadEvents ??= ref.read(downloadManagerProvider).events.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _prefetchDemand?.clearPrefetchWindow(this);
    _downloadEvents?.cancel();
    for (final controller in _transformations.values) {
      controller.dispose();
    }
    for (final progress in _progress.values) {
      progress.dispose();
    }
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

  /// Scrubbing only warms the small image beside the thumb. In particular it
  /// never asks the viewer for the original tier, so pages crossed during a
  /// drag cannot trigger a chain of full-size decodes.
  void _prefetchScrubWindow(int page) {
    if (!mounted) return;
    final urls = <int, String>{};
    for (final candidate in [page - 1, page, page + 1]) {
      if (candidate < 0 || candidate >= _pageCount) continue;
      final url =
          widget.entity?.squareUrlAt(candidate) ??
          widget.prefetchUrlForPage?.call(candidate);
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
          memCacheWidth: PixivImage.decodeWidthFor(
            _PageScrubber.thumbnailExtent,
          ),
        ).catchError((_) => ImagePreloadResult.failed),
      );
    }
  }

  void _onTransformed() {
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
    if (_viewerSessionChromeVisible == visible) return;
    _viewerSessionChromeVisible = visible;
    _setSystemChrome(visible: visible);
    setState(() {});
  }

  void _toggleChrome() => _setChromeVisible(!_chromeVisible);

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
      ..duration = MotionTokens.resolve(context, MotionTokens.fast)
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
    final page = await showAppBottomSheet<int>(
      context: context,
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
      showAppBottomSheet<void>(
        context: context,
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
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
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

  ValueNotifier<ImageLoadProgress> _progressFor(int page) => _progress
      .putIfAbsent(page, () => ValueNotifier(const ImageLoadProgress.idle()));

  TransformationController _transformationFor(int page) {
    return _transformations.putIfAbsent(page, TransformationController.new);
  }

  bool get _activeZoomed =>
      (_transformationFor(_activePage).value.getMaxScaleOnAxis()) >
      1.0 + precisionErrorTolerance;

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
            // Only the entry page's image shrinks back into the detail
            // page; from any other page the stage leaves downward.
            enabled: widget.heroTagForPage?.call(_activePage) == null,
            child: DragToDismiss(
              enabled: !_activeZoomed,
              onDismissed: () => Navigator.of(context).pop<void>(),
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
                  body: Stack(
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          // Tap toggles chrome; double-tap runs the zoom cycle.
                          // One detector registers both so the framework arena does
                          // the ~kDoubleTapTimeout disambiguation (risks R1 — no
                          // custom timer).
                          onTap: _toggleChrome,
                          onDoubleTapDown: (details) =>
                              _doubleTapFocal = details.localPosition,
                          onDoubleTap: _onDoubleTap,
                          child: _pageCount == 0
                              ? Center(
                                  child: Text(
                                    text('viewerNoImages'),
                                    style: TextStyle(
                                      color: FuncTokens.lightBackground,
                                    ),
                                  ),
                                )
                              : PageView.builder(
                                  controller: _pageController,
                                  physics: _activeZoomed
                                      ? const NeverScrollableScrollPhysics()
                                      : const PageScrollPhysics(),
                                  itemCount: _pageCount,
                                  itemBuilder: _buildPage,
                                ),
                        ),
                      ),
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
  void _zoomBy(double factor) =>
      _zoomAt(MediaQuery.sizeOf(context).center(Offset.zero), factor);

  void _zoomAt(Offset focal, double factor) {
    final target = _transformationFor(_activePage);
    _animateZoom(target, _focalZoom(focal, factor)..multiply(target.value));
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
                  transitionKey: heroTag,
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
        final hero = Hero(
          tag: heroTag,
          flightShuttleBuilder: illustHeroFlightShuttleBuilder,
          child: IllustHeroFlightChild(
            // The return shuttle paints the exact provider the
            // viewer is showing (same URL + uncapped decode =>
            // same decoded cache entry => identical pixels).
            // Painting the fixed detail tier here downgraded an
            // already-loaded original to large at flight start —
            // the flash seen when popping back to the detail page.
            popChild: SizedBox.expand(
              child: PixivImage(
                url: widget.urls[page],
                fit: BoxFit.contain,
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
              _PageScrubber(
                key: const Key('viewer-page-scrubber'),
                count: _pageCount,
                current: _activePage,
                value: _scrubPage ?? _activePage,
                onChanged: _onScrubChanged,
                onChangeEnd: _onScrubEnd,
                pageLabel: (page) =>
                    context.l10n.viewerPageLabel(page + 1, _pageCount),
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

class _PageScrubber extends StatelessWidget {
  const _PageScrubber({
    super.key,
    required this.count,
    required this.current,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    required this.pageLabel,
  });

  static const double thumbnailExtent = 72;

  final int count;
  final int current;
  final int value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final String Function(int page) pageLabel;

  @override
  Widget build(BuildContext context) {
    final color = FuncTokens.lightBackground;
    final dragging = value != current;
    return Semantics(
      label: pageLabel(value),
      value: pageLabel(value),
      slider: true,
      child: SizedBox(
        height: 64,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (dragging)
              Align(
                alignment: Alignment.topCenter,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: FuncTokens.imageControl,
                    borderRadius: FuncShape.control,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FuncSpacing.sm,
                      vertical: FuncSpacing.xs,
                    ),
                    child: Text(
                      pageLabel(value),
                      style: TextStyle(
                        color: color,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              top: 16,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: color,
                  inactiveTrackColor: color.withValues(alpha: 0.35),
                  thumbColor: color,
                  overlayColor: color.withValues(alpha: 0.16),
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 24,
                  ),
                ),
                child: Slider(
                  min: 0,
                  max: (count - 1).toDouble(),
                  divisions: count - 1,
                  value: value.toDouble(),
                  label: pageLabel(value),
                  onChanged: onChanged,
                  onChangeEnd: onChangeEnd,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Slides the viewer down off the screen while its route pops, for exits
/// without a Hero to carry the image back. The slide runs from wherever the
/// pop starts (a committed back gesture may begin it mid-way), so it never
/// jumps.
class _ExitSlide extends StatefulWidget {
  const _ExitSlide({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<_ExitSlide> createState() => _ExitSlideState();
}

class _ExitSlideState extends State<_ExitSlide> {
  Animation<double>? _route;

  /// The route value when the pop began; null while not popping.
  double? _popFrom;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)?.animation;
    if (identical(route, _route)) return;
    _route?.removeStatusListener(_onStatus);
    _route = route?..addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    final route = _route;
    if (route == null || !mounted) return;
    final popFrom = status == AnimationStatus.reverse && widget.enabled
        ? route.value
        : null;
    if (popFrom != _popFrom) setState(() => _popFrom = popFrom);
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_onStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final popFrom = _popFrom;
    // One shape whether popping or not, so the start of a pop never
    // rebuilds the viewer below.
    return AnimatedBuilder(
      animation: _route ?? kAlwaysCompleteAnimation,
      builder: (context, child) {
        final route = _route;
        final progress = route == null || popFrom == null || popFrom <= 0
            ? 0.0
            : ((popFrom - route.value) / popFrom).clamp(0.0, 1.0);
        return FractionalTranslation(
          translation: Offset(0, MotionTokens.pageCurve.transform(progress)),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

enum _ChromeEdge { top, bottom }

/// One chrome bar (top or bottom). Hidden chrome stays mounted — dropping
/// the subtree raced the semantics flush ('!child.attached' in
/// SemanticsNode._replaceChildren when a page turn lands mid-hide), so the
/// bar fades via Opacity and drops out of semantics/hit-testing instead.
class _ChromeEdgeBar extends StatefulWidget {
  const _ChromeEdgeBar({
    required this.visible,
    required this.edge,
    required this.child,
  });

  final bool visible;
  final _ChromeEdge edge;
  final Widget child;

  @override
  State<_ChromeEdgeBar> createState() => _ChromeEdgeBarState();
}

class _ChromeEdgeBarState extends State<_ChromeEdgeBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      value: widget.visible ? 1 : 0,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = MotionTokens.resolve(context, MotionTokens.fast);
  }

  @override
  void didUpdateWidget(covariant _ChromeEdgeBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      if (widget.visible) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: widget.edge == _ChromeEdge.top ? 0 : null,
      bottom: widget.edge == _ChromeEdge.bottom ? 0 : null,
      left: 0,
      right: 0,
      child: ExcludeSemantics(
        excluding: !widget.visible,
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Opacity(
              opacity: _controller.value,
              // alwaysIncludeSemantics: ExcludeSemantics owns the hidden
              // state; the Opacity stays semantics-complete so the tree
              // never sees a node vanish mid-flush.
              alwaysIncludeSemantics: true,
              child: child,
            ),
            // The stage is always black, whatever the theme.
            child: ArtworkControls(
              glyph: FuncTokens.onImageControl,
              halo: Colors.black,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// The jump sheet's thumbnail grid: about [_cellExtent] per cell, at least
/// [_minColumns] across. The current page carries a primary outline and
/// opens scrolled into view.
class _PageJumpGrid extends StatefulWidget {
  const _PageJumpGrid({
    required this.count,
    required this.current,
    required this.thumbnailFor,
    required this.onSelected,
  });

  static const double _cellExtent = 96;
  static const int _minColumns = 3;
  static const double _spacing = FuncSpacing.sm;
  static const double _padding = FuncSpacing.lg;

  /// The grid scrolls past this share of the screen height.
  static const double _maxHeightFactor = 0.6;

  final int count;
  final int current;
  final String Function(int page) thumbnailFor;
  final ValueChanged<int> onSelected;

  @override
  State<_PageJumpGrid> createState() => _PageJumpGridState();
}

class _PageJumpGridState extends State<_PageJumpGrid> {
  ScrollController? _scroll;

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = _PageJumpGrid._spacing;
        const padding = _PageJumpGrid._padding;
        final inner = constraints.maxWidth - padding * 2;
        final columns = math.max(
          _PageJumpGrid._minColumns,
          ((inner + spacing) / (_PageJumpGrid._cellExtent + spacing)).floor(),
        );
        final cell = (inner - spacing * (columns - 1)) / columns;
        final rows = (widget.count / columns).ceil();
        final rowExtent = cell + spacing;
        final contentHeight = rows * rowExtent - spacing + padding * 2;
        final height = math.min(
          contentHeight,
          MediaQuery.sizeOf(context).height * _PageJumpGrid._maxHeightFactor,
        );
        // The current page's row opens with one row of context above it.
        final currentRow = widget.current ~/ columns;
        _scroll ??= ScrollController(
          initialScrollOffset: ((currentRow - 1) * rowExtent).clamp(
            0,
            math.max(0, contentHeight - height),
          ),
        );
        return SizedBox(
          height: height,
          child: GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(padding),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
            ),
            itemCount: widget.count,
            itemBuilder: (context, page) => _PageThumbnail(
              page: page,
              count: widget.count,
              url: widget.thumbnailFor(page),
              extent: cell,
              current: page == widget.current,
              onTap: () => widget.onSelected(page),
            ),
          ),
        );
      },
    );
  }
}

class _PageThumbnail extends StatelessWidget {
  const _PageThumbnail({
    required this.page,
    required this.count,
    required this.url,
    required this.extent,
    required this.current,
    required this.onTap,
  });

  static const double _outline = 2;
  static const double _badgeInset = FuncSpacing.xs;

  final int page;
  final int count;
  final String url;
  final double extent;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Semantics(
      key: ValueKey('viewer-jump-page-$page'),
      container: true,
      button: true,
      selected: current,
      label: context.l10n.viewerPageLabel(page + 1, count),
      onTap: onTap,
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: FuncShape.control,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PixivImage.feed(url, layoutWidth: extent),
            PositionedDirectional(
              start: _badgeInset,
              bottom: _badgeInset,
              child: EntityBadge(label: '${page + 1}'),
            ),
            Material(
              type: MaterialType.transparency,
              child: InkWell(onTap: onTap),
            ),
            if (current)
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: FuncShape.control,
                    border: Border.all(color: primary, width: _outline),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
