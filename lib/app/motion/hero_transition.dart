import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

import '../../core/debug/frame_probe.dart';
import '../navigation/home_shell_metrics.dart';
import '../theme/func_semantic_tokens.dart';
import 'hero_rect_clip.dart';

/// Hero flight geometry shared by the feed cards and the detail page.
/// The Hero tag and shuttle builder are the single artwork transition
/// contract (component-guidelines.md "Detail Transition").
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
  const IllustHeroFlightChild({super.key, this.popChild, required this.child});

  final Widget child;
  final Widget? popChild;

  @override
  Widget build(BuildContext context) => child;
}

/// Feed-card end of the artwork Hero: the rounded clip, no outline. The
/// shared shuttle recognises it on the card side.
class IllustHeroCardFrame extends StatelessWidget {
  const IllustHeroCardFrame({super.key, this.cropAspect, required this.child});

  final Widget child;

  /// Set when the card shows only the top of a taller image: the image's
  /// width / height. The shuttle then grows the cropped top into the whole
  /// image instead of starting from a shrunken full frame.
  final double? cropAspect;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(borderRadius: FuncShape.card, child: child);
  }
}

/// Lays the shuttle image out between the card's top crop and the detail's
/// contained frame. Both rects keep the image's own [aspect], so the
/// detail's `BoxFit.contain` image fills the rect exactly; the shuttle clip
/// cuts off what the card did not show.
class _CropLerpDelegate extends SingleChildLayoutDelegate {
  const _CropLerpDelegate({required this.progress, required this.aspect});

  /// 0 at the card, 1 at the detail page, in both directions.
  final double progress;
  final double aspect;

  Rect _rect(Size size) {
    final coverTop = Offset.zero & Size(size.width, size.width / aspect);
    final fitted = applyBoxFit(BoxFit.contain, Size(aspect, 1), size);
    final containCenter = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    return Rect.lerp(coverTop, containCenter, progress)!;
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tight(_rect(constraints.biggest).size);

  @override
  Offset getPositionForChild(Size size, Size childSize) => _rect(size).topLeft;

  @override
  bool shouldRelayout(_CropLerpDelegate oldDelegate) =>
      progress != oldDelegate.progress || aspect != oldDelegate.aspect;
}

/// Conservative fallback for the home shell bottom navigation when the
/// Hero's context sits outside the shell — a plain MaterialApp in tests.
/// The normal path reads [HomeShellChrome.bottomBarExtent], so this only
/// serves scope-free hosts.
const _kHomeBottomNavHeight = 80.0;

/// Shared artwork Hero flight.
///
/// Hero shuttles are painted in the Navigator overlay, above both route
/// entries. The route's AppBar, pinned profile headers and shell navigation
/// therefore cannot occlude the shuttle by themselves. The boundary is
/// sampled from both endpoint viewports and interpolated with the same flight
/// progress as the Hero position. At the beginning of either direction the
/// image is clipped by the page it leaves; at the end it is clipped by the
/// page it enters. This moving boundary is important: a static intersection
/// produces the hard cut seen when returning from a scrolled profile, while
/// no clip lets an opening image paint over the destination chrome.
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
  final cardHero =
      (direction == HeroFlightDirection.push ? fromHeroContext : toHeroContext)
          .widget;
  final cardFrame = cardHero is Hero ? cardHero.child : null;
  final cropAspect = cardFrame is IllustHeroCardFrame
      ? cardFrame.cropAspect
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
  final shuttle = AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      if (size.isEmpty) {
        return HeroRectClip(globalRect: Rect.zero, child: child!);
      }
      // Corner radius follows the flight animation itself: it runs 0→1 on
      // push and 1→0 on pop, and the detail endpoint is always the 1 side —
      // so radius = lerp(card 12 → rect 0) by the raw value either way. A
      // constant radius used to land rounded then snap square on push.
      final rawProgress = animation.value;
      final progress = rawProgress.isFinite
          ? rawProgress.clamp(0.0, 1.0).toDouble()
          : (direction == HeroFlightDirection.push ? 1.0 : 0.0);
      final radius = BorderRadius.lerp(
        _illustHeroBorderRadius,
        BorderRadius.zero,
        progress,
      )!;
      return HeroRectClip(
        globalRect: _heroFlightClipRect(
          flightContext,
          fromHeroContext,
          toHeroContext,
          direction,
          animation.value,
          size: size,
          from: from,
          to: to,
          fallbackFrom: fallbackFrom,
          fallbackTo: fallbackTo,
          fromHome: fromHome,
          toHome: toHome,
          visibleExtent: visibleExtent,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: cropAspect == null
              ? child
              : CustomSingleChildLayout(
                  delegate: _CropLerpDelegate(
                    progress: progress,
                    aspect: cropAspect,
                  ),
                  child: child,
                ),
        ),
      );
    },
  );
  // The shuttle is mounted for exactly the flight: the frame probe counts
  // it as a live scene.
  return FrameProbe.available
      ? ProbeScene(scene: 'hero', child: shuttle)
      : shuttle;
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
  HeroFlightDirection direction,
  double animationValue, {
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

  final rawProgress = direction == HeroFlightDirection.push
      ? animationValue
      : 1 - animationValue;
  final progress = rawProgress.isFinite
      ? rawProgress.clamp(0.0, 1.0).toDouble()
      : (direction == HeroFlightDirection.push ? 1.0 : 0.0);

  // Horizontal route-slide transforms are intentionally ignored. The Hero
  // rect itself is already in Navigator coordinates, while the chrome spans
  // the navigator width; interpolating endpoint x values would make the clip
  // disappear into the offstage route for the first frames.
  //
  // fromHeroContext/toHeroContext are already departure/arrival endpoints
  // for both directions, and progress is normalised to flight progress —
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
  final scroll = context.findAncestorWidgetOfExactType<CustomScrollView>();
  if (scroll != null) {
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
