import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

import '../../core/debug/frame_probe.dart';
import '../../core/debug/hero_anomaly_log.dart';
import '../../core/log.dart';
import '../../core/settings/shared_preferences.dart';
import '../../l10n/context.dart';
import '../navigation/home_shell_metrics.dart';
import '../theme/func_semantic_tokens.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/app_top_bar.dart';
import 'hero_rect_clip.dart';
import 'motion_tokens.dart';

part 'hero_anomaly.dart';
part 'hero_lifted_bars.dart';

/// Hero flight geometry shared by the feed cards and the detail page.
/// The Hero tag and shuttle builder are the single artwork transition
/// contract (`frontend/transitions.md`).
/// Detail page replicating beta56 illust.dart: images with download mode,
/// author block, meta row, caption, tag chips (R2/R4/R5).
String illustHeroTag(String scope, int illustId) =>
    'IllustHero:$scope:$illustId';

/// Optional lightweight source used only when a Hero flies back to a feed.
///
/// Detail pages keep their full-quality [child] mounted so opening the viewer
/// still starts from the sharp image. Returning to a card, however, should
/// shuttle the card-sized preview that was already decoded by the feed; the
/// large detail texture otherwise has to be uploaded and resampled on the
/// first reverse-flight frame. The wrapper is intentionally transparent in
/// the normal widget tree and is interpreted by the shared shuttle below.
class IllustHeroFlightChild extends StatelessWidget {
  const IllustHeroFlightChild({
    super.key,
    this.popChild,
    this.containsImage = false,
    required this.child,
  });

  final Widget child;
  final Widget? popChild;

  /// Whether the image is contained in a larger endpoint (the viewer's
  /// full-screen stage) rather than filling it. The image then has the
  /// other endpoint's shape, and [HeroLiftHole] cuts nothing out of the
  /// stage: it fades out whole.
  final bool containsImage;

  @override
  Widget build(BuildContext context) => child;
}

/// Feed-card end of the artwork Hero: the rounded clip, no outline. The
/// shared shuttle recognises it on the card side.
class IllustHeroCardFrame extends StatelessWidget {
  const IllustHeroCardFrame({
    super.key,
    this.cropAspect,
    this.topSquare = false,
    required this.child,
  });

  final Widget child;

  /// Set when the card shows only part of the image, the top of a taller
  /// one or the middle of a wider one: the image's width / height. The
  /// shuttle then lays the image out covering the flight rect, cut to it,
  /// instead of starting from a shrunken full frame.
  final double? cropAspect;

  /// Whether [child] is pixiv's square thumbnail of the work's top, a file
  /// of its own: the detail page starts from it alone, and a return brings
  /// it back over the top of the detail image as the flight nears the card.
  final bool topSquare;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(borderRadius: FuncShape.card, child: child);
  }
}

/// Chrome drawn over a Hero image: a card's badges, the detail page's top
/// bar, page counter and action bar. The flying image is painted above
/// every page, so chrome over either end of a flight was covered as the
/// flight set off and uncovered whole as it landed, and a card's badges
/// floated over its empty slot. While a flight runs, the chrome its ends
/// overlap is hidden; once the image has landed it fades in.
class HeroChrome extends StatefulWidget {
  const HeroChrome({super.key, required this.child});

  final Widget child;

  /// Each route's chrome, for the flights that start or land on it.
  static final _byRoute = Expando<Set<_HeroChromeState>>();

  static Iterable<_HeroChromeState> _on(Route<dynamic> route) =>
      _byRoute[route] ?? const {};

  @override
  State<HeroChrome> createState() => _HeroChromeState();
}

class _HeroChromeState extends State<HeroChrome>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shown = AnimationController(
    vsync: this,
    value: 1,
  );
  late final CurvedAnimation _opacity = CurvedAnimation(
    parent: _shown,
    curve: MotionTokens.stateFadeCurve,
  );
  Route<dynamic>? _route;

  /// Flights holding the chrome hidden.
  int _holds = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolved here: a flight may land while this chrome's page goes.
    _shown.duration = MotionTokens.resolve(context, MotionTokens.stateFade);
    final route = ModalRoute.of(context);
    if (route == _route) return;
    _unregister();
    _route = route;
    _register();
  }

  // Only chrome in the tree is measured against a flight.
  void _register() {
    if (_route case final route?) (HeroChrome._byRoute[route] ??= {}).add(this);
  }

  void _unregister() {
    if (_route case final route?) HeroChrome._byRoute[route]?.remove(this);
  }

  @override
  void activate() {
    super.activate();
    _register();
  }

  @override
  void deactivate() {
    _unregister();
    super.deactivate();
  }

  /// Whether the chrome overlaps [rect], in global coordinates.
  bool _over(Rect rect) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    return MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    ).overlaps(rect);
  }

  void _hold() {
    _holds++;
    _shown.value = 0;
  }

  void _release() {
    _holds--;
    if (_holds == 0 && mounted) _shown.forward();
  }

  @override
  void dispose() {
    _unregister();
    _opacity.dispose();
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _opacity, child: widget.child);
}

/// How much the shared-element pages over a route cover it: a flight
/// between the route and a page over it is cut by the chrome of the page
/// that shows, so the clip follows this, not the image's way. The page
/// fades in and out faster than the image flies; a clip that followed the
/// image left it over the bar below a page already gone, or cut by that
/// bar under a page already shown.
///
/// A page registers its opacity under the route right below it for its
/// life. That route holds the card itself, or the navigator holding it:
/// the viewer goes on the root navigator, over the shell whose branch
/// navigator holds the detail page. Two pages over one route are a page
/// leaving and its successor opening while the image turns around; the
/// more opaque one counts.
abstract final class HeroPageCover {
  static final _covers =
      <
        Route<dynamic>,
        List<({Route<dynamic> page, Animation<double> opacity})>
      >{};

  static void add(
    Route<dynamic> below,
    Route<dynamic> page,
    Animation<double> opacity,
  ) => (_covers[below] ??= []).add((page: page, opacity: opacity));

  static void remove(Route<dynamic> below, Route<dynamic> page) {
    final covers = _covers[below];
    if (covers == null) return;
    covers.removeWhere((cover) => cover.page == page);
    if (covers.isEmpty) _covers.remove(below);
  }

  /// The pages over the innermost route holding a card whose ancestors are
  /// [cardAncestors] (each element by its distance from the card).
  static List<({Route<dynamic> page, Animation<double> opacity})> _over(
    Map<Element, int> cardAncestors,
  ) {
    var covers = const <({Route<dynamic> page, Animation<double> opacity})>[];
    int? nearest;
    for (final MapEntry(key: below, value: pages) in _covers.entries) {
      final subtree = below is ModalRoute ? below.subtreeContext : null;
      final distance = cardAncestors[subtree];
      if (distance == null || (nearest != null && distance > nearest)) continue;
      nearest = distance;
      covers = pages;
    }
    return covers;
  }

  /// The cover over the card now, or null when no page registered one.
  static double? _of(Map<Element, int> cardAncestors) {
    final covers = _over(cardAncestors);
    if (covers.isEmpty) return null;
    return covers.map((cover) => cover.opacity.value).reduce(math.max);
  }
}

/// Lays the shuttle image out at its own [aspect] covering the flight
/// rect, top-aligned and centered across: the card's crop sits on the card
/// at one end, the whole image on the detail rect (which has the image's
/// ratio) at the other. A taller image runs full width, a wider one full
/// height; the shuttle cuts it to the rect. Fitting the image
/// inside the rect instead shrank it narrower than the rect mid-flight,
/// then widened it back — a second shrink on top of the flight's own.
class _CoverTopDelegate extends SingleChildLayoutDelegate {
  const _CoverTopDelegate({required this.aspect});

  /// The image's width / height.
  final double aspect;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final rect = constraints.biggest;
    final width = math.max(rect.width, rect.height * aspect);
    return BoxConstraints.tight(Size(width, width / aspect));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      Offset((size.width - childSize.width) / 2, 0);

  @override
  bool shouldRelayout(_CoverTopDelegate oldDelegate) =>
      aspect != oldDelegate.aspect;
}

/// Conservative fallback for the home shell bottom navigation when the
/// Hero's context sits outside the shell — a plain MaterialApp in tests.
/// The normal path reads [HomeShellChrome.bottomBarExtent], so this only
/// serves scope-free hosts.
const _kHomeBottomNavHeight = 80.0;

/// The path of an artwork flight: the center rides Material's arc while
/// both sides scale by the same progress. Material's default tween arcs
/// two opposite corners instead, so between rects of different size and
/// shape one side lands long before the other — a history cover reached
/// its width, then shrank a step more in height.
RectTween illustHeroRectTween(Rect? begin, Rect? end) =>
    MaterialRectCenterArcTween(begin: begin, end: end);

/// Shared artwork Hero flight.
///
/// Hero shuttles are painted in the Navigator overlay, above both route
/// entries. The route's AppBar, pinned profile headers and shell navigation
/// therefore cannot occlude the shuttle by themselves. The boundary is
/// sampled from both endpoint viewports and interpolated by how much the
/// page over the card shows ([HeroPageCover]; by the Hero position where
/// no page registered). At the beginning of either direction the image is
/// clipped by the page it leaves; at the end it is clipped by the page it
/// enters. This moving boundary is important: a static intersection
/// produces the hard cut seen when returning from a scrolled profile, while
/// no clip lets an opening image paint over the destination chrome.
///
/// A card's flight to and from its page draws the card page's bars over
/// the image instead ([_LiftedBars]), which then is clipped at the other
/// end alone.
Widget illustHeroFlightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final heroContext = direction == HeroFlightDirection.push
      ? toHeroContext
      : fromHeroContext;
  final hero = heroContext.widget as Hero;
  // RepaintBoundary keeps the image's own layer alive between frames: the
  // clip boundary changes every frame, so without the boundary the whole
  // image subtree repaints each tick. With it, only the clip layer is
  // re-composited.
  final heroChild = hero.child;
  final shuttleChild =
      direction == HeroFlightDirection.pop &&
          heroChild is IllustHeroFlightChild &&
          heroChild.popChild != null
      ? heroChild.popChild!
      : heroChild;
  final child = RepaintBoundary(child: shuttleChild);
  // The card endpoint is the source on push and the destination on pop.
  final cardContext = direction == HeroFlightDirection.push
      ? fromHeroContext
      : toHeroContext;
  inspectHeroFlight(
    flightContext: flightContext,
    direction: direction,
    card: cardContext,
    other: identical(cardContext, fromHeroContext)
        ? toHeroContext
        : fromHeroContext,
  );
  final cardHero = cardContext.widget;
  final cardChild = cardHero is Hero ? cardHero.child : null;
  // Detail and viewer are both square: only a flight to or from a card
  // rounds its corners.
  final cardFrame = cardChild is IllustHeroCardFrame ? cardChild : null;
  final cropAspect = cardFrame?.cropAspect;
  final returningSquare =
      direction == HeroFlightDirection.pop && cardFrame?.topSquare == true
      ? RepaintBoundary(child: cardFrame!.child)
      : null;
  // Resolve all geometry before the animation starts. The old implementation
  // performed RenderObject walks and NestedScrollView header discovery from
  // AnimatedBuilder; the first return therefore paid that cost on a frame
  // budget and often fell to 30/60 FPS. The viewport and chrome are stable for
  // one flight, so the shuttle only interpolates two plain Rects below.
  final size = _heroScreenSize(flightContext, fromHeroContext, toHeroContext);
  // The home-side endpoint keeps its raw viewport bottom: the floating bar
  // slides in and out under it, so the flight clip caps that edge per frame
  // from the live visible extent below.
  final fromHome = _heroIsHomeSide(fromHeroContext);
  final toHome = _heroIsHomeSide(toHeroContext);
  final homeContext = fromHome
      ? fromHeroContext
      : (toHome ? toHeroContext : null);
  final visibleExtent = homeContext == null
      ? null
      : HomeShellChrome.maybeOf(homeContext)?.bottomBarVisibleExtent;
  final measuredFrom = size.isEmpty
      ? null
      : _heroMeasuredViewport(fromHeroContext, size, isHome: fromHome);
  final measuredTo = size.isEmpty
      ? null
      : _heroMeasuredViewport(toHeroContext, size, isHome: toHome);
  final fallbackFrom = size.isEmpty
      ? null
      : _fallbackHeroEndpoint(flightContext, fromHeroContext, size);
  final fallbackTo = size.isEmpty
      ? null
      : _fallbackHeroEndpoint(flightContext, toHeroContext, size);
  final from = measuredFrom ?? fallbackFrom;
  final to = measuredTo ?? fallbackTo;
  final fromBox = _heroScreenRect(fromHeroContext)?.size;
  final toBox = _heroScreenRect(toHeroContext)?.size;
  final cardIsFrom = identical(cardContext, fromHeroContext);
  // A card's flight to and from its page lifts the card page's bars over
  // the image ([_LiftedBars]).
  final liftBars = cardFrame == null || size.isEmpty
      ? null
      : () => _LiftedBars.capture(
          card: cardContext,
          push: direction == HeroFlightDirection.push,
          viewport: cardIsFrom ? from : to,
          size: size,
          home: cardIsFrom ? fromHome : toHome,
          visibleExtent: visibleExtent,
        );
  final shuttle = AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) => LayoutBuilder(
      builder: (context, constraints) {
        if (size.isEmpty) {
          return HeroRectClip(globalRect: Rect.zero, child: child!);
        }
        // How far the image has flown, read off its own size between the
        // two endpoints' (the flight lerps the rect): a flight turned
        // around or sent to a new page keeps the [animation] of the route
        // it started with, which may stop or run the other way. Endpoints
        // of about one size fall back to that animation.
        final progress =
            _progressBySize(constraints.biggest, fromBox, toBox) ??
            _routeProgress(animation.value, direction);
        final detailProgress = cardIsFrom ? progress : 1 - progress;
        final radius = cardFrame == null ? null : _cardRadiusAt(detailProgress);
        // A cropped card's image covers the flight rect and is cut to it,
        // the way an uncropped card's image fills it: the image only scales
        // and the rect opens out over what the card hid.
        Widget shaped = child!;
        if (cropAspect != null) {
          shaped = CustomSingleChildLayout(
            delegate: _CoverTopDelegate(aspect: cropAspect),
            child: shaped,
          );
        }
        if (returningSquare != null) {
          // The rect's top square is the image's: it covers the rect by
          // width while the rect is taller than wide.
          shaped = Stack(
            fit: StackFit.expand,
            children: [
              shaped,
              Align(
                alignment: Alignment.topCenter,
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Opacity(
                    opacity: _topSquareReturn.transform(
                      _routeProgress(animation.value, direction),
                    ),
                    child: returningSquare,
                  ),
                ),
              ),
            ],
          );
        }
        if (radius != null) {
          shaped = ClipRRect(borderRadius: radius, child: shaped);
        } else if (cropAspect != null) {
          shaped = ClipRect(child: shaped);
        }
        final lifted = context.findAncestorStateOfType<_LiftedEndpointsState>()
          ?.._holdPages();
        // Under the card page's lifted bars the image is cut at the page
        // it flies to alone; the card end is the whole screen. Elsewhere
        // the clip follows the page over the card, where one shows.
        final bars = lifted?._bars;
        final cover = lifted?._cover();
        final clipProgress = bars != null || cover == null
            ? progress
            : (cardIsFrom ? cover : 1 - cover);
        final openFrom = bars != null && cardIsFrom;
        final openTo = bars != null && !cardIsFrom;
        final clipped = HeroRectClip(
          globalRect: _heroFlightClipRect(
            flightContext,
            fromHeroContext,
            toHeroContext,
            clipProgress,
            size: size,
            from: openFrom ? Offset.zero & size : from,
            to: openTo ? Offset.zero & size : to,
            fallbackFrom: fallbackFrom,
            fallbackTo: fallbackTo,
            fromHome: fromHome && !openFrom,
            toHome: toHome && !openTo,
            visibleExtent: visibleExtent,
          ),
          child: shaped,
        );
        if (bars == null) return clipped;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: clipped),
            Positioned.fill(
              child: _LiftedBarsPaint(bars: bars, shown: 1 - detailProgress),
            ),
          ],
        );
      },
    ),
  );
  // The shuttle is mounted for exactly the flight: the frame probe counts
  // it as a live scene, and the endpoints stay lifted out of their pages.
  return _LiftedEndpoints(
    from: fromHeroContext,
    to: toHeroContext,
    card: cardContext,
    liftBars: liftBars,
    child: FrameProbe.available
        ? ProbeScene(scene: 'hero', child: shuttle)
        : shuttle,
  );
}

/// Keeps both endpoints of one flight lifted out of their pages
/// ([HeroLiftHole]), and the chrome over them hidden ([HeroChrome]), for
/// as long as the shuttle is mounted. A diverted flight rebuilds the
/// shuttle in place with its new endpoints.
class _LiftedEndpoints extends StatefulWidget {
  const _LiftedEndpoints({
    required this.from,
    required this.to,
    required this.card,
    required this.liftBars,
    required this.child,
  });

  final BuildContext from;
  final BuildContext to;

  /// The endpoint on the route below: [from] or [to].
  final BuildContext card;

  /// Captures the card page's bars to draw over the image; null for a
  /// flight that lifts none.
  final _LiftedBars? Function()? liftBars;
  final Widget child;

  @override
  State<_LiftedEndpoints> createState() => _LiftedEndpointsState();
}

class _LiftedEndpointsState extends State<_LiftedEndpoints> {
  List<VoidCallback> _releases = const [];
  final _held = <_HeroChromeState>{};

  /// The elements above the card by distance, for [HeroPageCover].
  Map<Element, int> _cardAncestors = const {};

  /// Where the image sits on the page over the card.
  Rect? _pageRect;

  /// The card page's bars over the image, captured once, as the flight
  /// takes off: the screen of a flight sent on to a new page already holds
  /// the image and these bars.
  _LiftedBars? _bars;

  void _lift() {
    final page = identical(widget.card, widget.from) ? widget.to : widget.from;
    _cardAncestors = {};
    widget.card.visitAncestorElements((element) {
      _cardAncestors[element] = _cardAncestors.length;
      return true;
    });
    _pageRect = _heroScreenRect(page);
    _releases = [
      ?HeroLiftHole.lift(widget.from),
      ?HeroLiftHole.lift(widget.to),
    ];
    if ((_bars, ModalRoute.of(page)) case (final bars?, final route?)) {
      HeroBarsCover._cover(route, bars.rects);
      _releases = [..._releases, () => HeroBarsCover._uncover(route)];
    }
    _holdOver(ModalRoute.of(widget.card), _heroScreenRect(widget.card));
    _holdOver(ModalRoute.of(page), _pageRect);
  }

  /// Hides the chrome over the image on the pages over the card. A card
  /// opened again while its image flies home sends the flight on to the
  /// new page without rebuilding it: that page's chrome is found here,
  /// where the old page had the image.
  void _holdPages() {
    for (final cover in HeroPageCover._over(_cardAncestors)) {
      _holdOver(cover.page, _pageRect);
    }
  }

  double? _cover() => HeroPageCover._of(_cardAncestors);

  void _holdOver(Route<dynamic>? route, Rect? rect) {
    if (route == null || rect == null) return;
    for (final chrome in HeroChrome._on(route)) {
      if (_held.contains(chrome) || !chrome._over(rect)) continue;
      chrome._hold();
      _held.add(chrome);
    }
  }

  void _release() {
    for (final release in _releases) {
      release();
    }
    for (final chrome in _held) {
      chrome._release();
    }
    _held.clear();
  }

  @override
  void initState() {
    super.initState();
    _bars = widget.liftBars?.call();
    _lift();
  }

  @override
  void didUpdateWidget(_LiftedEndpoints oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.from, widget.from) ||
        !identical(oldWidget.to, widget.to)) {
      _release();
      _lift();
    }
  }

  @override
  void dispose() {
    _release();
    _bars?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Wraps a shared-element page's content. While the page leaves and one of
/// its Hero endpoints is in flight, the endpoint's image is cut out of the
/// content: what is under it (the page's background layer) shows through
/// where the image was lifted off, not whatever the content drew there.
///
/// Opening has no hole: the content fades in over that layer anyway, and
/// the image's slow last stretch left a line around it on the shown page. A settled page (covered by the viewer, or
/// revealed by it) has none either: the route below it is not painted. Nor
/// does an endpoint that contains its image ([IllustHeroFlightChild]
/// `containsImage`, the viewer's stage): the image's spot, sharp-edged
/// and clear while the rest of the dark stage faded, read as a window.
class HeroLiftHole extends SingleChildRenderObjectWidget {
  const HeroLiftHole({super.key, required this.animation, super.child});

  /// The page's own route controller, not its animation: the animation
  /// reports complete for the frame a Hero measures the opening page.
  /// The hole opens only while it runs after the page has landed.
  final Animation<double> animation;

  /// Cuts the Hero endpoint at [heroContext] out of its page until the
  /// returned callback runs. Null when the endpoint is in no such page or
  /// contains its image.
  static VoidCallback? lift(BuildContext heroContext) {
    final page = heroContext
        .findAncestorRenderObjectOfType<_RenderHeroLiftHole>();
    final box = heroContext.findRenderObject();
    final hero = heroContext.widget;
    final flightChild = hero is Hero ? hero.child : null;
    if (page == null ||
        box is! RenderBox ||
        (flightChild is IllustHeroFlightChild && flightChild.containsImage)) {
      return null;
    }
    page._add(box);
    return () => page._remove(box);
  }

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeroLiftHole(animation);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderHeroLiftHole).animation = animation;
  }
}

class _RenderHeroLiftHole extends RenderProxyBox {
  _RenderHeroLiftHole(this._animation);

  Animation<double> _animation;
  set animation(Animation<double> value) {
    if (identical(value, _animation)) return;
    if (attached) {
      _animation.removeStatusListener(_onStatus);
      value.addStatusListener(_onStatus);
    }
    _animation = value;
    markNeedsPaint();
  }

  /// The lifted endpoints' Hero placeholder boxes.
  final _lifts = <RenderBox>[];
  final _clip = LayerHandle<ClipPathLayer>();

  void _add(RenderBox lift) {
    _lifts.add(lift);
    if (attached) markNeedsPaint();
  }

  void _remove(RenderBox lift) {
    if (_lifts.remove(lift) && attached) markNeedsPaint();
  }

  /// Whether the page has been fully shown: only then does a flight lift
  /// the image off it.
  bool _landed = false;

  void _onStatus(AnimationStatus status) {
    if (status.isCompleted) _landed = true;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    if (_animation.isCompleted) _landed = true;
    _animation.addStatusListener(_onStatus);
  }

  @override
  void detach() {
    _animation.removeStatusListener(_onStatus);
    super.detach();
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  /// Where the lifted images sit in this page, or null for no hole.
  Rect? _hole() {
    if (!_landed || _animation.isCompleted) return null;
    Rect? hole;
    for (final box in _lifts) {
      if (!box.attached || !box.hasSize) continue;
      final rect = MatrixUtils.transformRect(
        box.getTransformTo(this),
        Offset.zero & box.size,
      );
      hole = hole?.expandToInclude(rect) ?? rect;
    }
    return hole;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final hole = _hole();
    if (child == null || hole == null) {
      _clip.layer = null;
      super.paint(context, offset);
      return;
    }
    final bounds = Offset.zero & size;
    _clip.layer = context.pushClipPath(
      needsCompositing,
      offset,
      bounds,
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(bounds)
        ..addRect(hole),
      super.paint,
      clipBehavior: Clip.hardEdge,
      oldLayer: _clip.layer,
    );
  }
}

/// The measured viewport clip for one flight endpoint, or null when the
/// endpoint is not laid out yet (detached route on the first flight frame).
/// Null keeps the fallback path in [_heroFlightClipRect].
Rect? _heroMeasuredViewport(
  BuildContext heroContext,
  Size size, {
  required bool isHome,
}) {
  RenderObject? renderObject = heroContext.findRenderObject();
  RenderSliver? viewportSliver;
  while (renderObject != null) {
    if (renderObject is RenderSliver) {
      // The first sliver above the Hero belongs to the nearest viewport. Its
      // approximate paint clip includes NestedScrollView overlap (for
      // example a pinned profile tab row), which viewport.size alone misses.
      viewportSliver ??= renderObject;
    }
    if (renderObject is RenderViewportBase &&
        renderObject.axis == Axis.vertical &&
        renderObject.hasSize) {
      try {
        final localClip =
            viewportSliver == null || viewportSliver.geometry == null
            ? Offset.zero & renderObject.size
            : renderObject.describeApproximatePaintClip(viewportSliver) ??
                  (Offset.zero & renderObject.size);
        final bounds = MatrixUtils.transformRect(
          renderObject.getTransformTo(null),
          localClip,
        );
        if (bounds.isFinite && bounds.height > 0) {
          final viewportBounds = Rect.fromLTRB(
            0,
            bounds.top.clamp(0.0, size.height).toDouble(),
            size.width,
            bounds.bottom.clamp(0.0, size.height).toDouble(),
          );
          // A viewport can intentionally paint under an edge-to-edge AppBar
          // (and a NestedScrollView can paint under pinned headers). The
          // endpoint's actual chrome is still an occlusion boundary, so
          // combine both measurements instead of trusting viewport.size
          // alone. This also keeps non-scrollable Hero endpoints consistent
          // with scrollable ones.
          final chrome = _fallbackHeroEndpoint(null, heroContext, size);
          final top = math.max(viewportBounds.top, chrome.top);
          // Home-side: the floating bar's cap moves during the flight, so
          // the measured rect keeps the raw viewport bottom and the frame
          // pass applies the live edge. Other endpoints use the static
          // chrome bound as before.
          final bottom = isHome
              ? viewportBounds.bottom
              : math.min(viewportBounds.bottom, chrome.bottom);
          if (bottom > top) {
            return Rect.fromLTRB(0, top, size.width, bottom);
          }
          return viewportBounds;
        }
      } on Object {
        // The route may be detached while a diverted flight is being
        // measured. A null result keeps recomputing on the next frame.
      }
      return null;
    }
    renderObject = renderObject.parent;
  }
  return null;
}

/// Returns the UI occlusion boundary for one frame of a Hero flight.
///
/// [Animation.value] is the route animation value. A push runs 0 -> 1; a pop
/// runs 1 -> 0, while Flutter's Hero overlay uses a reversed proxy for the
/// latter. Normalising here keeps the clip and the shuttle position moving in
/// the same direction for both transitions.
Rect _heroFlightClipRect(
  BuildContext flightContext,
  BuildContext fromContext,
  BuildContext toContext,
  double progress, {
  required Size size,
  Rect? from,
  Rect? to,
  Rect? fallbackFrom,
  Rect? fallbackTo,
  bool fromHome = false,
  bool toHome = false,
  ValueListenable<double>? visibleExtent,
}) {
  if (size.isEmpty) return Rect.zero;
  final screen = Offset.zero & size;
  var fromRect =
      from ??
      fallbackFrom ??
      _fallbackHeroEndpoint(flightContext, fromContext, size);
  var toRect =
      to ?? fallbackTo ?? _fallbackHeroEndpoint(flightContext, toContext, size);

  // The home-side bottom edge tracks the bar's *live* covered height: the
  // bar slides back in during a return flight, so a resting-extent cap cuts
  // the image before it has anywhere to land. Outside the shell there is no
  // live value — keep the conservative constant. Measured home endpoints
  // carry the raw viewport bottom, so this cap is the only bar-related one.
  if (fromHome) {
    fromRect = _capHeroBottom(fromRect, size, visibleExtent);
  }
  if (toHome) {
    toRect = _capHeroBottom(toRect, size, visibleExtent);
  }

  // Horizontal route-slide transforms are intentionally ignored. The Hero
  // rect itself is already in Navigator coordinates, while the chrome spans
  // the navigator width; interpolating endpoint x values would make the clip
  // disappear into the offstage route for the first frames.
  //
  // fromHeroContext/toHeroContext are already departure/arrival endpoints
  // for both directions, and progress runs from the one to the other —
  // lerp(from, to, progress) is correct as-is for push and pop.
  final top = _lerp(
    fromRect.top,
    toRect.top,
    progress,
  ).clamp(0.0, size.height).toDouble();
  final bottom = _lerp(
    fromRect.bottom,
    toRect.bottom,
    progress,
  ).clamp(0.0, size.height).toDouble();
  if (bottom <= top) {
    // A route can be offstage for one frame while HeroController measures it.
    // Fall back to conservative chrome bounds rather than returning an empty
    // clip (which makes the artwork disappear for the whole flight).
    return _fallbackHeroFlightClipRect(
      flightContext,
      departureContext: fromContext,
      arrivalContext: toContext,
      size: size,
      progress: progress,
      from: fromRect,
      to: toRect,
    );
  }
  return Rect.fromLTRB(0, top, size.width, bottom).intersect(screen);
}

double _lerp(double begin, double end, double t) => begin + (end - begin) * t;

Size _heroScreenSize(
  BuildContext flightContext,
  BuildContext fromContext,
  BuildContext toContext,
) {
  for (final context in [flightContext, fromContext, toContext]) {
    final media = MediaQuery.maybeOf(context);
    final size = media?.size;
    if (size != null && size.isFinite && !size.isEmpty) return size;
  }
  final navigator = Navigator.maybeOf(flightContext);
  final renderObject = navigator?.context.findRenderObject();
  if (renderObject is RenderBox && renderObject.hasSize) {
    try {
      final bounds = MatrixUtils.transformRect(
        renderObject.getTransformTo(null),
        Offset.zero & renderObject.size,
      );
      if (bounds.isFinite && !bounds.isEmpty) return bounds.size;
    } on Object {
      // A detached overlay has no usable global transform. Returning an
      // empty size below makes the clip a safe no-op instead of throwing
      // during a route transition.
    }
  }
  return Size.zero;
}

Rect _fallbackHeroFlightClipRect(
  BuildContext flightContext, {
  required BuildContext departureContext,
  required BuildContext arrivalContext,
  required Size size,
  required double progress,
  Rect? from,
  Rect? to,
}) {
  final departure =
      from ?? _fallbackHeroEndpoint(flightContext, departureContext, size);
  final arrival =
      to ?? _fallbackHeroEndpoint(flightContext, arrivalContext, size);
  final top = _lerp(
    departure.top,
    arrival.top,
    progress,
  ).clamp(0.0, size.height).toDouble();
  final bottom = _lerp(
    departure.bottom,
    arrival.bottom,
    progress,
  ).clamp(0.0, size.height).toDouble();
  if (bottom <= top) return Offset.zero & size;
  return Rect.fromLTRB(0, top, size.width, bottom);
}

Rect _fallbackHeroEndpoint(
  BuildContext? flightContext,
  BuildContext heroContext,
  Size size,
) {
  final top = _heroTopChrome(flightContext, heroContext);
  final bottom = _heroBottomEdge(heroContext, size);
  return Rect.fromLTRB(0, top, size.width, bottom);
}

/// Status bar + app bar + pinned header of one flight end.
double _heroTopChrome(BuildContext? context, BuildContext heroContext) {
  final media =
      MediaQuery.maybeOf(heroContext) ??
      (context == null ? null : MediaQuery.maybeOf(context));
  final statusTop = media?.viewPadding.top ?? media?.padding.top ?? 0;
  final scaffold = heroContext.findAncestorWidgetOfExactType<Scaffold>();
  final appBar = scaffold?.appBar;
  // A see-through toolbar over artwork hides nothing: the image lands
  // under it. Its status strip stays opaque.
  if (appBar is AppTopBar && !appBar.occludesContent) {
    return statusTop + _pinnedHeaderChrome(heroContext, statusTop);
  }
  final appBarChrome = appBar is PreferredSizeWidget
      ? appBar.preferredSize.height
      : 0;
  return statusTop + appBarChrome + _pinnedHeaderChrome(heroContext, statusTop);
}

/// Whether this flight endpoint lives on a branch-root route — the only
/// place the floating shell bottom bar exists.
bool _heroIsHomeSide(BuildContext heroContext) =>
    ModalRoute.of(heroContext)?.isFirst ?? false;

/// Applies the home-side bottom cap to one endpoint rect for the current
/// frame. With the shell's live [visibleExtent] the bar's real covered
/// height wins; scope-free hosts keep the static conservative constant.
Rect _capHeroBottom(Rect rect, Size size, ValueListenable<double>? extent) {
  final limit = extent != null
      ? size.height - extent.value
      : (size.height - _kHomeBottomNavHeight).clamp(0.0, size.height);
  if (rect.bottom <= limit) return rect;
  return Rect.fromLTRB(
    rect.left,
    rect.top,
    rect.right,
    math.max(rect.top, limit.toDouble()),
  );
}

double _heroBottomEdge(BuildContext heroContext, Size size) {
  if (!_heroIsHomeSide(heroContext)) return size.height;

  // The shell publishes the bar's resting extent through HomeShellChrome —
  // the same computed value the spacer and SnackBar margin use. Outside
  // the shell (a plain MaterialApp in tests) fall back to the conservative
  // constant, matching pre-scope behaviour.
  final extent = HomeShellChrome.maybeOf(heroContext)?.bottomBarExtent;
  if (extent != null) {
    return size.height - extent;
  }
  return (size.height - _kHomeBottomNavHeight)
      .clamp(0.0, size.height)
      .toDouble();
}

/// Collapsed height of pinned persistent headers in the landing page's scroll
/// containers, minus the status inset. A profile Hero lives in the inner
/// [CustomScrollView] of a [NestedScrollView], so looking at only one of
/// those ancestors misses the profile header (the profile-specific hard-cut
/// regression). Include both layers; the render viewport remains the source
/// of truth when it can provide an overlap-aware paint clip.
double _pinnedHeaderChrome(BuildContext context, double statusInset) {
  double fromSliver(SliverPersistentHeader header) {
    final h = header.delegate.minExtent;
    return h > 0 ? h : 0;
  }

  double total = 0;
  // Any CustomScrollView, subtypes too: feeds use DeferredCacheScrollView.
  CustomScrollView? scroll;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is! CustomScrollView) return true;
    scroll = widget;
    return false;
  });
  if (scroll case final scroll?) {
    for (final sliver in scroll.slivers) {
      if (sliver is SliverPersistentHeader && sliver.pinned) {
        total += fromSliver(sliver);
      }
    }
  }
  final nested = context.findAncestorWidgetOfExactType<NestedScrollView>();
  if (nested != null) {
    for (final sliver in nested.headerSliverBuilder(context, false)) {
      if (sliver is SliverPersistentHeader && sliver.pinned) {
        total += fromSliver(sliver);
      }
    }
  }
  return total > 0 ? math.max(0, total - statusInset) : 0;
}

const _illustHeroBorderRadius = FuncShape.card;

/// The card end's corner radius [detailProgress] of the way to the detail
/// end: card 12 → square 0. A constant radius used to land rounded then
/// snap square on push.
BorderRadius _cardRadiusAt(double detailProgress) => BorderRadius.lerp(
  _illustHeroBorderRadius,
  BorderRadius.zero,
  detailProgress,
)!;

/// When a top-square card's own thumbnail comes back over the detail
/// image, in the time of a return: Android's `MaterialContainerTransform`
/// fades a return's start view back over 60–90%. Whatever quality the
/// detail shows, the flight lands on the card's own file.
const _topSquareReturn = Interval(0.6, 0.9);

/// Flight progress from the route [value]: it runs 0→1 on push and 1→0
/// on pop.
double _routeProgress(double value, HeroFlightDirection direction) {
  final push = direction == HeroFlightDirection.push;
  if (!value.isFinite) return push ? 1 : 0;
  final clamped = value.clamp(0.0, 1.0).toDouble();
  return push ? clamped : 1 - clamped;
}

/// The Hero box at [context] on screen, transforms included (a pressed
/// card is scaled down), as the Hero measures its flight rect; null
/// before layout.
Rect? _heroScreenRect(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );
}

/// How far a shuttle of [size] is from the [from] size towards the [to]
/// size, or null when the two differ too little to tell.
double? _progressBySize(Size size, Size? from, Size? to) {
  if (from == null || to == null) return null;
  final dw = to.width - from.width;
  final dh = to.height - from.height;
  final span = dw * dw + dh * dh;
  if (span < _minSizeSpan * _minSizeSpan) return null;
  final along =
      ((size.width - from.width) * dw + (size.height - from.height) * dh) /
      span;
  return along.clamp(0.0, 1.0).toDouble();
}

/// The smallest size change between two endpoints, in logical pixels, that
/// [_progressBySize] reads progress from.
const _minSizeSpan = 16.0;
