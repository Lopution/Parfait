import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/motion/drag_to_dismiss.dart';
import '../../../app/motion/hero_transition.dart';
import '../../../app/pixiv_image.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../app/theme/func_tokens.dart';
import '../../../l10n/lookup.dart';
import '../../../l10n/context.dart';

/// Fullscreen horizontal viewer replicating beta56 ImageScalePage
/// (R3): `n / total` title, horizontal paging, per-page zoom clamped to
/// 0.9–6.0, initial page restored, swiping suspended while zoomed.
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.urls,
    this.initialPage = 0,
    this.heroTagForPage,
    this.onPageChanged,
    this.tierKeyForPage,
    this.tier,
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

  /// Zoom bounds (PRD R3: strictly 0.9–6.0).
  static const double minScale = 0.9;
  static const double maxScale = 6.0;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _pageController;
  final _transformations = <int, TransformationController>{};
  int _activePage = 0;

  int get _pageCount => widget.urls.length;

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
  }

  @override
  void dispose() {
    for (final controller in _transformations.values) {
      controller.dispose();
    }
    _pageController.dispose();
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
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: FuncTokens.lightBackground,
          title: Text('${_activePage + 1} / $_pageCount'),
        ),
        body: _pageCount == 0
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
                itemBuilder: (context, page) {
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
              ),
      ),
    );
  }

  bool _isZoomed(int page) =>
      _transformationFor(page).value.getMaxScaleOnAxis() >
      1.0 + precisionErrorTolerance;
}
