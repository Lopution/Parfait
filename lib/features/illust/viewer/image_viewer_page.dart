import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/motion/drag_to_dismiss.dart';
import '../../../app/motion/motion_tokens.dart';
import '../../../app/motion/hero_transition.dart';
import '../../../app/pixiv_image.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/network/compat/network_providers.dart';
import '../../../app/theme/func_tokens.dart';
import '../../../l10n/lookup.dart';
import '../../../l10n/context.dart';

/// Whether the viewer chrome (top bar + bottom bar) is visible. This is
/// session-level state (revision ①): it deliberately survives page turns,
/// keyboard turns, page-sheet jumps and `replaceImageViewerPage` route
/// swaps — the user asked for an immersive view and it stays immersive
/// until they ask otherwise. Per-page state (zoom/pan) resets normally.
bool _viewerSessionChromeVisible = true;

/// Test hook: resets the session-level viewer state so widget tests are
/// independent of each other's chrome toggles.
@visibleForTesting
void debugResetViewerSession() {
  _viewerSessionChromeVisible = true;
}

/// Fullscreen horizontal viewer replicating beta56 ImageScalePage
/// (R3): `n / total` title, horizontal paging, per-page zoom clamped to
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

class _ImageViewerPageState extends ConsumerState<ImageViewerPage> {
  late final PageController _pageController;
  final _transformations = <int, TransformationController>{};
  int _activePage = 0;

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
    _pageController.addListener(_onPageChanged);
    _transformationFor(_activePage).addListener(_onTransformed);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _prefetchNeighbours(_activePage),
    );
    if (!_viewerSessionChromeVisible) _setSystemChrome(visible: false);
  }

  @override
  void dispose() {
    for (final controller in _transformations.values) {
      controller.dispose();
    }
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
    final ProviderContainer container;
    try {
      container = ProviderScope.containerOf(context, listen: false);
    } on StateError {
      return;
    }
    final cacheManager = container
        .read(pixivNetworkFactoryProvider)
        .imageCacheManager;
    for (final neighbour in [page - 1, page + 1]) {
      if (neighbour < 0 || neighbour >= _pageCount) continue;
      final url = urlFor(neighbour);
      if (url == null) continue;
      unawaited(
        PixivImage.preload(
          context,
          url,
          cacheManager: cacheManager,
          tierKey: widget.tierKeyForPage?.call(neighbour),
          tier: IllustImageTier.medium,
        ).catchError((_) {}),
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
      SystemChrome.setEnabledSystemUIMode(
        visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      ).catchError((_) {}),
    );
  }

  void _setChromeVisible(bool visible) {
    if (_viewerSessionChromeVisible == visible) return;
    _viewerSessionChromeVisible = visible;
    _setSystemChrome(visible: visible);
    setState(() {});
  }

  void _toggleChrome() => _setChromeVisible(!_chromeVisible);

  TransformationController _transformationFor(int page) {
    return _transformations.putIfAbsent(page, TransformationController.new);
  }

  bool get _activeZoomed =>
      (_transformationFor(_activePage).value.getMaxScaleOnAxis()) >
      1.0 + precisionErrorTolerance;

  @override
  Widget build(BuildContext context) {
    String text(String key) => l10nLookup(context.l10n, key);
    // The fullscreen viewer deliberately keeps an opaque black canvas so
    // artwork and its white chrome match the replica surface.
    return DragToDismiss(
      enabled: !_activeZoomed,
      onDismissed: () => Navigator.of(context).pop<void>(),
      child: Scaffold(
        // primary: false — the media fills the whole screen edge to edge;
        // each chrome bar SafeAreas its own controls.
        primary: false,
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // A lone tap toggles the chrome; the gesture arena gives
                // the media area priority over InteractiveViewer's pan
                // recognizers only after the double-tap window resolves.
                onTap: _toggleChrome,
                child: _pageCount == 0
                    ? Center(
                        child: Text(
                          text('viewerNoImages'),
                          style: TextStyle(color: FuncTokens.lightBackground),
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
              child: _buildBottomBar(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(BuildContext context, int page) {
    return Builder(
      builder: (context) {
        final heroTag = widget.heroTagForPage?.call(page);
        final viewer = InteractiveViewer(
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
            ),
          ),
        );
        if (heroTag == null) return viewer;
        return Hero(
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
              ),
            ),
            child: viewer,
          ),
        );
      },
    );
  }

  /// Top chrome: back affordance + the `n / total` counter. The counter is
  /// plain text here — it becomes a jump-to-page entry with the bottom
  /// toolbar (stage C13).
  Widget _buildTopBar(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            // Imperative pop: explicit exits never route through the
            // system-back intercept chain (W1 split).
            BackButton(
              color: FuncTokens.lightBackground,
              onPressed: () => Navigator.of(context).pop<void>(),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                '${_activePage + 1} / $_pageCount',
                style: TextStyle(color: FuncTokens.lightBackground),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Bottom chrome. The fullscreen toggle is one of the three chrome
  /// channels (media tap / this button / keyboard F); the rest of the
  /// toolbar lands with the action row (stage C13).
  Widget _buildBottomBar(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            const Spacer(),
            IconButton(
              tooltip: _chromeVisible
                  ? context.l10n.viewerEnterFullscreen
                  : context.l10n.viewerExitFullscreen,
              onPressed: _toggleChrome,
              icon: Icon(
                _chromeVisible ? Icons.fullscreen : Icons.fullscreen_exit,
                color: FuncTokens.lightBackground,
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
      duration: MotionTokens.fast,
      value: widget.visible ? 1 : 0,
    );
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
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
