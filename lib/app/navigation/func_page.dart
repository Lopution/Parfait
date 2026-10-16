import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransition;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart'
    show
        FadeForwardsPageTransitionsBuilder,
        PredictiveBackPageTransitionsBuilder;

import '../../core/settings/app_settings.dart' show PageTransitionStyle;
import '../motion/hero_transition.dart' show HeroLiftHole;
import '../motion/motion_tokens.dart';
import '../motion/page_transitions.dart';
import '../widgets/home_branch_stack.dart' show BranchActivityScope;
import 'route_animation.dart';

/// The app's standard route page, animated by [transitionStyle]:
/// - [PageTransitionStyle.system]: Android gets
///   [PredictiveBackPageTransitionsBuilder] (predictive-back shared element
///   on Android U+, FadeForwards elsewhere); every other platform keeps the
///   [FuncRouteTransition] trailing-edge slide.
/// - [PageTransitionStyle.slide]: the official Cupertino slide on every
///   platform. On Android a back-gesture driver lets the system back
///   gesture scrub it.
///
/// A [sharedElement] page (one opened with a Hero from the page below)
/// has its own transition whatever the style: it fades in and out over a
/// still page below while its Hero flies, the way shared-element
/// transitions do on Android, iOS and in Flutter's own samples. A slide
/// would move both ends of the flight while the image crosses between
/// them. Under a page pushed on top it moves in the style like any page.
///
/// A hand-rolled [Page] instead of `CustomTransitionPage` because the
/// predictive-back builder's `buildTransitions` takes the [PageRoute]
/// itself (it listens for back-gesture events and reads
/// `popGestureEnabled`); a `transitionsBuilder` closure never sees it.
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
    this.transitionStyle = PageTransitionStyle.system,
    this.sharedElement = false,
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
  final PageTransitionStyle transitionStyle;

  /// Whether a Hero carries this page's content in from the page below (a
  /// card into its detail, a detail image into the viewer).
  final bool sharedElement;

  @override
  Route<T> createRoute(BuildContext context) => _FuncPageRoute<T>(this);
}

class _FuncPageRoute<T> extends PageRoute<T> {
  _FuncPageRoute(FuncPage<T> page) : super(settings: page);

  FuncPage<T> get _page => settings as FuncPage<T>;

  /// The route last announced above this one. A pop announces no new next
  /// route, so through a pop this is still the route leaving.
  _FuncPageRoute<dynamic>? _next;

  /// A shared-element page's opacity.
  late final Animation<double> _sharedElementFade = _SharedElementFade(
    this,
    controller!,
  );

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    _next = nextRoute is _FuncPageRoute ? nextRoute : null;
    super.didChangeNext(nextRoute);
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    _next = nextRoute is _FuncPageRoute ? nextRoute : null;
    super.didPopNext(nextRoute);
  }

  @override
  bool get barrierDismissible => _page.barrierDismissible;

  /// The slide darkens the page below like `CupertinoPageRoute`, except
  /// under a shared-element page, which only fades.
  @override
  Color? get barrierColor =>
      _page.transitionStyle == PageTransitionStyle.slide &&
          !fullscreenDialog &&
          !_page.sharedElement
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
  bool get popGestureEnabled {
    if (!super.popGestureEnabled) return false;
    // Every home-shell branch Navigator keeps an isCurrent route alive
    // while offscreen; only the settled visible branch may take the
    // predictive-back gesture (R15). Routes outside the shell — the root
    // Navigator and any inner Navigator — have no scope and fall through.
    final navigator = this.navigator;
    if (navigator == null) return false;
    return BranchActivityScope.maybeOf(navigator.context)?.active ?? true;
  }

  /// A shared-element page in the system style on Android takes the back
  /// gesture with its own driver around FadeForwards (which only moves it
  /// under a page pushed on top), not Material's predictive back: that
  /// one rewinds the route at the commit for its own commit animation, and
  /// the Hero, which follows the route, would jump back to the page.
  bool get _scrubsFadeForwards =>
      _page.sharedElement &&
      _page.transitionStyle == PageTransitionStyle.system &&
      defaultTargetPlatform == TargetPlatform.android;

  @override
  void handleCommitBackGesture() => commitBackGestureGuarded(
    navigator,
    _page.transitionStyle == PageTransitionStyle.slide || _page.sharedElement
        ? _commitWhereLeft
        : super.handleCommitBackGesture,
  );

  /// Under a shared-element page this page holds still, not in the
  /// predictive-back pose the navigator-wide gesture flag would pick.
  @override
  bool get popGestureInProgress {
    final next = _next;
    if (next != null &&
        next._page.sharedElement &&
        !next.animation!.isDismissed) {
      return false;
    }
    return super.popGestureInProgress;
  }

  /// The framework's commit rewinds the route to fully shown and pops from
  /// there, for Material's separate commit animation. A transition that
  /// follows the route animation itself (the slide, a Hero) would jump back
  /// under the finger, so this pops from where the gesture left it and
  /// ends the gesture once the pop has run.
  void _commitWhereLeft() {
    final navigator = this.navigator;
    final controller = this.controller!;
    if (isCurrent) navigator?.pop();
    if (!controller.isAnimating) {
      navigator?.didStopUserGesture();
      return;
    }
    late final AnimationStatusListener ended;
    ended = (_) {
      controller.removeStatusListener(ended);
      navigator?.didStopUserGesture();
    };
    controller.addStatusListener(ended);
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final page = RouteAnimationScope(
      animation: animation,
      child: Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        child: _page.child,
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
    final secondary = (_next?._page.sharedElement ?? false)
        ? kAlwaysDismissedAnimation
        : secondaryAnimation;
    Widget style(Widget child) => _styleTransition(
      context,
      shared ? kAlwaysCompleteAnimation : animation,
      secondary,
      child,
    );
    return FuncTransitionGuard(
      animation: animation,
      secondaryAnimation: secondary,
      transition: shared
          ? (child) => FadeTransition(
              opacity: _sharedElementFade,
              child: style(HeroLiftHole(animation: controller!, child: child)),
            )
          : style,
      child: child,
    );
  }

  Widget _styleTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final android = defaultTargetPlatform == TargetPlatform.android;
    switch (_page.transitionStyle) {
      case PageTransitionStyle.system when !android:
        return FuncRouteTransition(animation: animation, child: child);
      case PageTransitionStyle.system when _scrubsFadeForwards:
        // FadeForwards follows the finger, the way the Hero does; see
        // [_scrubsFadeForwards].
        return _BackGestureDriver(
          route: this,
          child: const FadeForwardsPageTransitionsBuilder().buildTransitions(
            this,
            context,
            animation,
            secondaryAnimation,
            child,
          ),
        );
      case PageTransitionStyle.system:
        // Carries its own back-gesture detector.
        return const PredictiveBackPageTransitionsBuilder().buildTransitions(
          this,
          context,
          animation,
          secondaryAnimation,
          child,
        );
      case PageTransitionStyle.slide:
        // The transition widget, not CupertinoPageTransitionsBuilder: the
        // builder adds an iOS edge-swipe back detector that would take
        // horizontal drags from in-page pagers. Back is the system gesture.
        final slide = CupertinoPageTransition(
          primaryRouteAnimation: animation,
          secondaryRouteAnimation: secondaryAnimation,
          linearTransition: popGestureInProgress,
          child: child,
        );
        return android ? _BackGestureDriver(route: this, child: slide) : slide;
    }
  }
}

/// A shared-element page's opacity: it fades over the first part of an
/// opening and over the first part of a leave (back, the back gesture),
/// so leaving it goes with the image rather than after it. One curve
/// played backwards would hold the page until the image had nearly
/// landed. Reads the controller: the route animation reports complete
/// for the frame a Hero measures the opening page.
class _SharedElementFade extends Animation<double>
    with AnimationWithParentMixin<double> {
  _SharedElementFade(this.route, this.parent);

  final _FuncPageRoute<dynamic> route;

  @override
  final Animation<double> parent;

  @override
  double get value {
    final leaving =
        parent.status == AnimationStatus.reverse || route.popGestureInProgress;
    return (leaving
            ? MotionTokens.sharedElementFadeOut
            : MotionTokens.sharedElementFadeIn)
        .transform(parent.value);
  }
}

/// Ends a Navigator user gesture when the route's pop throws. Flutter's
/// [TransitionRoute] normally stops the gesture after [NavigatorState.pop]
/// returns, so a synchronous error would otherwise leave the Navigator
/// absorbing all later pointers.
@visibleForTesting
void commitBackGestureGuarded(NavigatorState? navigator, VoidCallback commit) {
  try {
    commit();
  } catch (_) {
    if (navigator?.userGestureInProgress ?? false) {
      navigator!.didStopUserGesture();
    }
    rethrow;
  }
}

/// `CupertinoPageRoute`'s barrier over the page below a slide.
const _slideBarrierColor = Color(0x18000000);

/// Hands the Android predictive back gesture to [route] so the slide
/// transition follows the finger: the same forwarding as Material's private
/// predictive-back detector, without its own visuals. Only the visible top
/// route takes the gesture ([PageRoute.popGestureEnabled] includes the
/// branch visibility gate); otherwise the gesture falls through to a plain
/// pop on commit.
class _BackGestureDriver extends StatefulWidget {
  const _BackGestureDriver({required this.route, required this.child});

  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_BackGestureDriver> createState() => _BackGestureDriverState();
}

class _BackGestureDriverState extends State<_BackGestureDriver>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The binding sends update, cancel and commit only to observers that
  // returned true from start.
  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final route = widget.route;
    if (backEvent.isButtonEvent ||
        !route.isCurrent ||
        !route.popGestureEnabled) {
      return false;
    }
    route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) => widget
      .route
      .handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);

  @override
  void handleCancelBackGesture() => widget.route.handleCancelBackGesture();

  @override
  void handleCommitBackGesture() => widget.route.handleCommitBackGesture();

  @override
  Widget build(BuildContext context) => widget.child;
}
