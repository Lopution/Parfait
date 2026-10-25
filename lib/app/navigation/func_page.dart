import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransition;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Theme;

import '../motion/hero_transition.dart'
    show HeroBarsCover, HeroLiftHole, HeroPageCover;
import '../motion/motion_tokens.dart';
import '../motion/page_transitions.dart';
import 'frozen_while_hidden.dart';
import 'route_animation.dart';

/// The app's standard route page: it slides in from the trailing edge over
/// a darkened, parallaxed page below ([CupertinoPageTransition]) on every
/// platform. Back, the button or the system gesture, pops it as one plain
/// pop; nothing follows the finger.
///
/// A [sharedElement] page (one opened with a Hero from the page below)
/// does not move while its Hero flies, the way shared-element transitions
/// do on Android, iOS and in Flutter's own samples: a slide would move
/// both ends of the flight while the image crosses between them. With a
/// [sharedElementBackdrop] its background covers the page below first and
/// its content fades in on it; leaving, the content goes first, then the
/// background. Without one the whole page fades. Under a page pushed on
/// top it slides like any page.
///
/// Field defaults mirror `CustomTransitionPage`.
class FuncPage<T> extends Page<T> {
  const FuncPage({
    required this.child,
    this.transitionDuration = MotionTokens.pageTransition,
    this.reverseTransitionDuration = MotionTokens.pageTransition,
    this.maintainState = true,
    this.fullscreenDialog = false,
    this.opaque = true,
    this.barrierDismissible = false,
    this.barrierColor,
    this.barrierLabel,
    this.sharedElement = false,
    this.sharedElementBackdrop = true,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;
  final Duration transitionDuration;
  final Duration reverseTransitionDuration;
  final bool maintainState;
  final bool fullscreenDialog;
  final bool opaque;
  final bool barrierDismissible;
  final Color? barrierColor;
  final String? barrierLabel;

  /// Whether a Hero carries this page's content in from the page below (a
  /// card into its detail, a detail image into the viewer).
  final bool sharedElement;

  /// Whether a [sharedElement] page lays its background over the page below
  /// before its content shows. Off for the viewer: its dark stage covers
  /// the page below anyway, and a drag to dismiss it reveals that page.
  final bool sharedElementBackdrop;

  @override
  Route<T> createRoute(BuildContext context) => _FuncPageRoute<T>(this);
}

class _FuncPageRoute<T> extends PageRoute<T> {
  _FuncPageRoute(FuncPage<T> page) : super(settings: page);

  FuncPage<T> get _page => settings as FuncPage<T>;

  /// Each route's page right above it, announced by that page as it is
  /// pushed or moved. A pop announces nothing, so through a pop this is
  /// still the page leaving. Keyed by any route: a page can sit on a route
  /// that is not a [FuncPage].
  static final _above = Expando<_FuncPageRoute<dynamic>>();

  bool get _backdrop => _page.sharedElement && _page.sharedElementBackdrop;

  /// The slide in and out and the slide aside under a page pushed on top,
  /// on `CupertinoPageTransition`'s curves turning where they are
  /// ([TurnCurve]); the transition takes them as they are
  /// (`linearTransition`).
  late final Animation<double> _slideIn = TurnCurve.drive(
    animation!,
    curve: Curves.fastEaseInToSlowEaseOut,
  );
  late final Animation<double> _slideAside = TurnCurve.drive(
    secondaryAnimation!,
    curve: Curves.linearToEaseOut,
    reverseCurve: Curves.easeInToLinear,
  );

  // A shared-element page's layers show over their part of an opening and
  // hide over their part of a leave, both of the route value, which runs
  // 1 → 0 when leaving: one curve played backwards would hold a layer
  // until the image had nearly landed. They read the controller: the route
  // animation reports complete for the frame a Hero measures the opening
  // page.

  /// A shared-element page's background over the page below.
  late final Animation<double> _backdropFade = TurnCurve.drive(
    controller!,
    curve: MotionTokens.sharedElementBackdropIn,
    reverseCurve: MotionTokens.sharedElementBackdropOut,
  );

  /// A shared-element page's content: over its background, or over the
  /// page below without one.
  late final Animation<double> _contentFade = _backdrop
      ? TurnCurve.drive(
          controller!,
          curve: const _Primed(MotionTokens.sharedElementContentIn),
          reverseCurve: MotionTokens.sharedElementContentOut,
        )
      : TurnCurve.drive(
          controller!,
          curve: MotionTokens.sharedElementFadeIn,
          reverseCurve: MotionTokens.sharedElementFadeOut,
        );

  /// The route a shared-element page covers, for [HeroPageCover].
  Route<dynamic>? _covered;

  @override
  void didChangePrevious(Route<dynamic>? previousRoute) {
    if (previousRoute != null) _above[previousRoute] = this;
    if (_page.sharedElement && previousRoute != _covered) {
      _uncover();
      if (previousRoute != null) {
        // What hides the page below: the background where there is one.
        HeroPageCover.add(
          previousRoute,
          this,
          _backdrop ? _backdropFade : _contentFade,
        );
      }
      _covered = previousRoute;
    }
    super.didChangePrevious(previousRoute);
  }

  void _uncover() {
    if (_covered case final covered?) {
      HeroPageCover.remove(covered, this);
    }
  }

  @override
  void dispose() {
    _uncover();
    super.dispose();
  }

  @override
  bool get barrierDismissible => _page.barrierDismissible;

  /// The slide darkens the page below like `CupertinoPageRoute`; a
  /// shared-element page leaves the page below as it is.
  @override
  Color? get barrierColor => !fullscreenDialog && !_page.sharedElement
      ? _slideBarrierColor
      : _page.barrierColor;

  @override
  String? get barrierLabel => _page.barrierLabel;

  @override
  Duration get transitionDuration => _page.transitionDuration;

  @override
  Duration get reverseTransitionDuration => _page.reverseTransitionDuration;

  @override
  bool get maintainState => _page.maintainState;

  @override
  bool get fullscreenDialog => _page.fullscreenDialog;

  @override
  bool get opaque => _page.opaque;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final page = RouteAnimationScope(
      // The controller: [animation] reads complete while a Hero measures
      // the opening page (see RouteAnimationScope).
      animation: controller!,
      child: Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        child: FrozenWhileHidden(child: _page.child),
      ),
    );
    return page;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // One structure for the route's whole life, whatever the phase: the
    // page lives under the route's GlobalKey, and a changed widget type
    // here would reparent it, rebuilding the whole page in that frame.
    final shared = _page.sharedElement;
    final still = underSharedElement(this);
    final secondary = still ? kAlwaysDismissedAnimation : secondaryAnimation;
    return FuncTransitionGuard(
      animation: animation,
      secondaryAnimation: secondary,
      transition: (child) => IgnorePointer(
        // Leaving, nothing of the page takes a touch, so the page below
        // answers at once: while the image flies home, and where the
        // sliding page still is.
        ignoring: animation.status == AnimationStatus.reverse,
        // The transition widget, not CupertinoPageTransitionsBuilder: the
        // builder adds an iOS edge-swipe back detector that would take
        // horizontal drags from in-page pagers.
        child: CupertinoPageTransition(
          primaryRouteAnimation: shared ? kAlwaysCompleteAnimation : _slideIn,
          secondaryRouteAnimation: still
              ? kAlwaysDismissedAnimation
              : _slideAside,
          linearTransition: true,
          child: shared ? _sharedElementStage(context, child) : child,
        ),
      ),
      child: child,
    );
  }

  Widget _sharedElementStage(BuildContext context, Widget child) {
    final content = FadeTransition(
      opacity: _contentFade,
      child: HeroLiftHole(animation: controller!, child: child),
    );
    if (!_backdrop) return content;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: FadeTransition(
            opacity: _backdropFade,
            child: ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
          ),
        ),
        Positioned.fill(
          child: HeroBarsCover(
            route: this,
            color: Theme.of(context).scaffoldBackgroundColor,
          ),
        ),
        content,
      ],
    );
  }
}

/// Whether a shared-element page is entering or leaving right above
/// [route]. The page below holds still and stays live then: no secondary
/// motion, no snapshot, so it answers touches while the image flies.
bool underSharedElement(Route<dynamic> route) {
  final above = _FuncPageRoute._above[route];
  return above != null &&
      above._page.sharedElement &&
      !above.animation!.isDismissed;
}

/// [curve], but never below the faintest alpha that still paints once the
/// opening has begun. A layer at alpha 0 is not painted at all, so content
/// that waits for its fade drew a whole page of text for the first time
/// mid-flight, a raster frame of 12–20ms that stalled the image. Painted
/// unseen from the start, that first draw falls on takeoff, where the
/// image barely moves.
class _Primed extends Curve {
  const _Primed(this.curve);

  final Curve curve;

  static const _faintest = 1 / 255;

  @override
  double transformInternal(double t) => math.max(curve.transform(t), _faintest);
}

/// `CupertinoPageRoute`'s barrier over the page below a slide.
const _slideBarrierColor = Color(0x18000000);
