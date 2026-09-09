import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/home_shell_metrics.dart';
import 'hero_rect_clip.dart';

/// Hero flight geometry shared by the feed cards and the detail page.
/// The Hero tag and shuttle builder are the single artwork transition
/// contract (component-guidelines.md "Detail Transition").
/// Detail page replicating beta56 illust.dart: images with download mode,
/// author block, meta row, caption, tag chips (R2/R4/R5).
String illustHeroTag(String scope, int illustId) =>
    'IllustHero:$scope:$illustId';

/// Conservative fallback for the home shell bottom navigation before its
/// first rendered global edge has been published by [HomePage]. The normal
/// path uses [HomeShellMetrics.bottomNavTop], so this is only used in a
/// first-frame or test-only route with no measured shell.
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
  final child = ClipRRect(
    borderRadius: _illustHeroBorderRadius,
    child: hero.child,
  );
  return AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      return HeroRectClip(
        globalRect: _heroFlightClipRect(
          flightContext,
          fromHeroContext,
          toHeroContext,
          direction,
          animation.value,
        ),
        child: child!,
      );
    },
  );
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
  double animationValue,
) {
  final size = _heroScreenSize(flightContext, fromContext, toContext);
  if (size.isEmpty) return Rect.zero;
  final screen = Offset.zero & size;
  final from = _heroEndpointViewport(flightContext, fromContext, size);
  final to = _heroEndpointViewport(flightContext, toContext, size);

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
  final top = _lerp(
    from.top,
    to.top,
    progress,
  ).clamp(0.0, size.height).toDouble();
  final bottom = _lerp(
    from.bottom,
    to.bottom,
    progress,
  ).clamp(0.0, size.height).toDouble();
  if (bottom <= top) {
    // A route can be offstage for one frame while HeroController measures it.
    // Fall back to conservative chrome bounds rather than returning an empty
    // clip (which makes the artwork disappear for the whole flight).
    return _fallbackHeroFlightClipRect(
      flightContext,
      fromContext,
      toContext,
      size,
      progress,
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

Rect _heroEndpointViewport(
  BuildContext flightContext,
  BuildContext heroContext,
  Size size,
) {
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
          final chrome = _fallbackHeroEndpoint(
            flightContext,
            heroContext,
            size,
          );
          final top = math.max(viewportBounds.top, chrome.top);
          final bottom = math.min(viewportBounds.bottom, chrome.bottom);
          if (bottom > top) {
            return Rect.fromLTRB(0, top, size.width, bottom);
          }
          return viewportBounds;
        }
      } on Object {
        // The route may be detached while a diverted flight is being
        // measured. The conservative fallback below keeps the shuttle
        // visible and bounded instead of failing the transition.
      }
    }
    renderObject = renderObject.parent;
  }
  return _fallbackHeroEndpoint(flightContext, heroContext, size);
}

Rect _fallbackHeroFlightClipRect(
  BuildContext flightContext,
  BuildContext fromContext,
  BuildContext toContext,
  Size size,
  double progress,
) {
  final from = _fallbackHeroEndpoint(flightContext, fromContext, size);
  final to = _fallbackHeroEndpoint(flightContext, toContext, size);
  final top = _lerp(
    from.top,
    to.top,
    progress,
  ).clamp(0.0, size.height).toDouble();
  final bottom = _lerp(
    from.bottom,
    to.bottom,
    progress,
  ).clamp(0.0, size.height).toDouble();
  if (bottom <= top) return Offset.zero & size;
  return Rect.fromLTRB(0, top, size.width, bottom);
}

Rect _fallbackHeroEndpoint(
  BuildContext flightContext,
  BuildContext heroContext,
  Size size,
) {
  final top = _heroTopChrome(flightContext, heroContext);
  final bottom = _heroBottomEdge(heroContext, size);
  return Rect.fromLTRB(0, top, size.width, bottom);
}

/// Status bar + app bar + pinned header of one flight end.
double _heroTopChrome(BuildContext context, BuildContext heroContext) {
  final media = MediaQuery.maybeOf(heroContext) ?? MediaQuery.maybeOf(context);
  final statusTop = media?.viewPadding.top ?? media?.padding.top ?? 0;
  final scaffold = heroContext.findAncestorWidgetOfExactType<Scaffold>();
  final appBar = scaffold?.appBar;
  final appBarChrome = appBar is PreferredSizeWidget
      ? appBar.preferredSize.height
      : 0;
  return statusTop + appBarChrome + _pinnedHeaderChrome(heroContext, statusTop);
}

double _heroBottomEdge(BuildContext heroContext, Size size) {
  final isHomeRoute = ModalRoute.of(heroContext)?.isFirst ?? false;
  if (!isHomeRoute) return size.height;

  // HomePage publishes the actual global edge of its BottomAppBar. Unlike a
  // height-plus-safe-area calculation this cannot double-count the gesture or
  // three-button navigation inset.
  HomeShellMetrics? metrics;
  try {
    metrics = ProviderScope.containerOf(
      heroContext,
      listen: false,
    ).read(homeShellMetricsProvider);
  } on StateError {
    // Hero flights may run under a plain MaterialApp (no ProviderScope) in
    // tests; fall back to the conservative constant, matching pre-provider
    // behaviour.
  }
  final measuredTop = metrics?.bottomNavTop;
  if (measuredTop != null && measuredTop > 0 && measuredTop < size.height) {
    return measuredTop;
  }
  final measuredHeight = metrics?.bottomNavHeight ?? _kHomeBottomNavHeight;
  return (size.height - measuredHeight).clamp(0.0, size.height).toDouble();
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

const _illustHeroBorderRadius = BorderRadius.all(Radius.circular(12));
