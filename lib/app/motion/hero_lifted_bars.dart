part of 'hero_transition.dart';

/// The card page's bars, lifted over the image of a card's flight to and
/// from its page: the image passes under them, the way it would under a
/// real bar, and they slide off the screen as it opens and back as it
/// returns (Jetsnack's `renderInSharedTransitionScopeOverlay` with
/// `animateEnterExit`). Each bar keeps its background solid and fades its
/// content with the slide.
///
/// Captured as the flight takes off, the bands of the card page above and
/// below the card's viewport: the screen before a push, the card's page
/// on a pop, where the leaving page is over it on screen. Meanwhile the
/// page over the card covers the real bars ([HeroBarsCover]).
///
/// User decision (10-24) after three clip-only prototypes: a hard clip at
/// a bar that only fades cut the image along a line nobody could see, and
/// a whole bar fading over the image showed the image through it, split
/// in two.
class _LiftedBars {
  _LiftedBars(this.bars, this.background);

  final List<_LiftedBar> bars;

  /// Every bar's background: the page colour, opaque (the app's app bars,
  /// tab rows and navigation bar).
  final Color background;

  List<Rect> get rects => [for (final bar in bars) bar.rect];

  void dispose() {
    for (final bar in bars) {
      bar.image.dispose();
    }
  }

  /// The bars around the card's [viewport], across the card's page; null
  /// when there are none or nothing to read them from.
  static _LiftedBars? capture({
    required BuildContext card,
    required bool push,
    required Rect? viewport,
    required Size size,
    required bool home,
    required ValueListenable<double>? visibleExtent,
  }) {
    if (viewport == null) return null;
    final page = _pageBoundary(card);
    if (page == null) return null;
    final across = MatrixUtils.transformRect(
      page.getTransformTo(null),
      Offset.zero & page.size,
    ).intersect(Offset.zero & size);
    final shown = home
        ? _capHeroBottom(viewport, size, visibleExtent)
        : viewport;
    final bands = [
      (
        rect: Rect.fromLTRB(across.left, across.top, across.right, shown.top),
        up: true,
      ),
      (
        rect: Rect.fromLTRB(
          across.left,
          shown.bottom,
          across.right,
          across.bottom,
        ),
        up: false,
      ),
    ].where((band) => band.rect.width >= 1 && band.rect.height >= 1).toList();
    if (bands.isEmpty) return null;
    final source = push ? _screenLayer(card) : _pageLayer(card, page);
    if (source == null) return null;
    return _LiftedBars([
      for (final (:rect, :up) in bands)
        _LiftedBar(
          rect,
          source.layer.toImageSync(
            source.toLayer(rect),
            pixelRatio: source.pixelRatio,
          ),
          up: up,
        ),
    ], Theme.of(card).scaffoldBackgroundColor);
  }

  static RenderRepaintBoundary? _pageBoundary(BuildContext card) {
    final boundary = ModalRoute.of(card)?.subtreeContext?.findRenderObject();
    return boundary is RenderRepaintBoundary && boundary.hasSize
        ? boundary
        : null;
  }

  // The bands alone are captured from the layers last composited, so the
  // takeoff frame rasterizes two strips, not a whole page. Neither layer
  // has a public accessor (see `LayerCensus`).

  static _LayerSource? _screenLayer(BuildContext card) {
    RenderObject? node = card.findRenderObject();
    while (node != null && node is! RenderView) {
      node = node.parent;
    }
    if (node is! RenderView) return null;
    // ignore: invalid_use_of_protected_member
    final layer = node.layer;
    if (layer is! OffsetLayer) return null;
    // The root layer is in physical pixels.
    final toPhysical = node.configuration.toMatrix();
    return (
      layer: layer,
      toLayer: (rect) => MatrixUtils.transformRect(toPhysical, rect),
      pixelRatio: 1.0,
    );
  }

  static _LayerSource? _pageLayer(
    BuildContext card,
    RenderRepaintBoundary page,
  ) {
    // ignore: invalid_use_of_protected_member
    final layer = page.layer;
    if (layer is! OffsetLayer) return null;
    final origin = page.localToGlobal(Offset.zero);
    return (
      layer: layer,
      toLayer: (rect) => rect.shift(-origin),
      pixelRatio: MediaQuery.devicePixelRatioOf(card),
    );
  }
}

/// A layer to capture bars from, and how a rect on screen maps into it.
typedef _LayerSource = ({
  OffsetLayer layer,
  Rect Function(Rect) toLayer,
  double pixelRatio,
});

/// One bar of the card page, at [rect] on screen.
class _LiftedBar {
  const _LiftedBar(this.rect, this.image, {required this.up});

  final Rect rect;
  final ui.Image image;

  /// Whether it leaves over the top edge; else over the bottom.
  final bool up;
}

/// Paints [bars] [shown] of the way in from off the screen.
class _LiftedBarsPaint extends LeafRenderObjectWidget {
  const _LiftedBarsPaint({required this.bars, required this.shown});

  final _LiftedBars bars;
  final double shown;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLiftedBars(bars, shown);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderLiftedBars renderObject,
  ) {
    renderObject
      ..bars = bars
      ..shown = shown;
  }
}

class _RenderLiftedBars extends RenderBox {
  _RenderLiftedBars(this._bars, this._shown);

  _LiftedBars _bars;
  set bars(_LiftedBars value) {
    if (identical(value, _bars)) return;
    _bars = value;
    markNeedsPaint();
  }

  double _shown;
  set shown(double value) {
    if (value == _shown) return;
    _shown = value;
    markNeedsPaint();
  }

  /// Where the last paint put each bar on screen, and its content's
  /// opacity, for tests.
  @visibleForTesting
  List<({Rect rect, double opacity})> get debugLastPaintedBars => _lastPainted;
  List<({Rect rect, double opacity})> _lastPainted = const [];

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {
    final toLocal = offset - localToGlobal(Offset.zero);
    final shown = _shown.clamp(0.0, 1.0);
    final background = Paint()..color = _bars.background;
    final content = Paint()
      ..filterQuality = FilterQuality.low
      ..color = Color.fromRGBO(0, 0, 0, shown);
    final painted = <({Rect rect, double opacity})>[];
    for (final bar in _bars.bars) {
      final away = (1 - shown) * bar.rect.height * (bar.up ? -1 : 1);
      final rect = bar.rect.translate(0, away);
      painted.add((rect: rect, opacity: shown));
      final local = rect.shift(toLocal);
      context.canvas.drawRect(local, background);
      if (shown == 0) continue;
      final image = bar.image;
      context.canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        local,
        content,
      );
    }
    _lastPainted = painted;
  }
}

/// A layer of a shared-element page, over its background and under its
/// content: while a card flight lifts the bars of the page below over its
/// image ([_LiftedBars]), it paints over the real ones in the page colour,
/// so only the lifted bars move. The real ones show again as the flight
/// ends, where the lifted ones have come to rest.
class HeroBarsCover extends LeafRenderObjectWidget {
  const HeroBarsCover({super.key, required this.route, required this.color});

  /// The shared-element page this layer is on.
  final Route<dynamic> route;
  final Color color;

  /// The bars on screen each page covers while its flight lifts them.
  static final _covered = ValueNotifier<Map<Route<dynamic>, List<Rect>>>(
    const {},
  );

  static void _cover(Route<dynamic> route, List<Rect> rects) =>
      _covered.value = {..._covered.value, route: rects};

  static void _uncover(Route<dynamic> route) {
    if (!_covered.value.containsKey(route)) return;
    _covered.value = {
      for (final MapEntry(:key, :value) in _covered.value.entries)
        if (key != route) key: value,
    };
  }

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeroBarsCover(route, color);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderHeroBarsCover)
      ..route = route
      ..color = color;
  }
}

class _RenderHeroBarsCover extends RenderBox {
  _RenderHeroBarsCover(this._route, this._color);

  Route<dynamic> _route;
  set route(Route<dynamic> value) {
    if (identical(value, _route)) return;
    _route = value;
    markNeedsPaint();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  /// The rects on screen the last paint covered, for tests.
  @visibleForTesting
  List<Rect> get debugLastPaintedRects => _lastPainted;
  List<Rect> _lastPainted = const [];

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    HeroBarsCover._covered.addListener(_onCovered);
  }

  @override
  void detach() {
    HeroBarsCover._covered.removeListener(_onCovered);
    super.detach();
  }

  void _onCovered() {
    markNeedsPaint();
    // A flight uncovers as its shuttle is disposed, after the frame's
    // paint, when a repaint asks for no frame of its own.
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {
    final rects = HeroBarsCover._covered.value[_route] ?? const <Rect>[];
    _lastPainted = rects;
    if (rects.isEmpty) return;
    final toLocal = offset - localToGlobal(Offset.zero);
    final paint = Paint()..color = _color;
    for (final rect in rects) {
      context.canvas.drawRect(rect.shift(toLocal), paint);
    }
  }
}
