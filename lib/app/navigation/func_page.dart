import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransition;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart'
    show
        FadeForwardsPageTransitionsBuilder,
        PredictiveBackPageTransitionsBuilder;

import '../../core/settings/app_settings.dart' show PageTransitionStyle;
import '../motion/motion_tokens.dart';
import '../motion/page_transitions.dart';
import '../widgets/home_branch_stack.dart' show BranchActivityScope;

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
/// replaces the style with a fade over a still page below, so the flying
/// image is the only thing that moves; see [_SharedElementTransition].
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

  @override
  bool get barrierDismissible => _page.barrierDismissible;

  /// The slide darkens the page below like `CupertinoPageRoute`.
  @override
  Color? get barrierColor =>
      _page.transitionStyle == PageTransitionStyle.slide &&
          !fullscreenDialog &&
          !_page.sharedElement
      ? _slideBarrierColor
      : _page.barrierColor;

  /// The page below a shared-element page holds still: the Hero flies to
  /// or from a spot on it, which must not slide away under the flight. Its
  /// secondary animation still runs, so it counts as covered until a pop
  /// has finished — the home branch root keeps drawing its own copy of the
  /// bottom bar under the fading page instead of the shell's popping up
  /// over it. One builder per route: the framework skips a delegated
  /// transition equal to the receiving route's own, which would let a
  /// shared-element page below another (detail under viewer) move.
  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      _page.sharedElement ? _holdStill : null;

  Widget? _holdStill(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) => child;

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

  @override
  void handleCommitBackGesture() =>
      commitBackGestureGuarded(navigator, super.handleCommitBackGesture);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Semantics(
    scopesRoute: true,
    explicitChildNodes: true,
    child: _page.child,
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final android = defaultTargetPlatform == TargetPlatform.android;
    if (_page.sharedElement) {
      return FuncTransitionGuard(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        transition: (child) => _coveredMotion(
          context,
          secondaryAnimation,
          _SharedElementTransition(
            route: this,
            animation: animation,
            child: child,
          ),
        ),
        child: child,
      );
    }
    // FuncRouteTransition carries its own guard; every other path composes
    // the shared guard around the official transition.
    final Widget Function(Widget child) transition;
    switch (_page.transitionStyle) {
      case PageTransitionStyle.system when !android:
        return FuncRouteTransition(
          animation: animation,
          secondaryAnimation: secondaryAnimation,
          child: child,
        );
      case PageTransitionStyle.system:
        // Carries its own back-gesture detector.
        transition = (child) =>
            const PredictiveBackPageTransitionsBuilder().buildTransitions(
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
        transition = (child) => CupertinoPageTransition(
          primaryRouteAnimation: animation,
          secondaryRouteAnimation: secondaryAnimation,
          linearTransition: popGestureInProgress,
          child: child,
        );
    }
    final drive = android && _page.transitionStyle == PageTransitionStyle.slide;
    return FuncTransitionGuard(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      transition: drive
          ? (child) => _BackGestureDriver(route: this, child: transition(child))
          : transition,
      child: child,
    );
  }
}

extension on _FuncPageRoute<dynamic> {
  /// A shared-element page's own motion while an ordinary page covers it:
  /// the style's outgoing half, as every other page plays it. Off Android
  /// the system style's slide carries its own guard, so the page stays
  /// still there.
  Widget _coveredMotion(
    BuildContext context,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => switch (_page.transitionStyle) {
    PageTransitionStyle.system
        when defaultTargetPlatform == TargetPlatform.android =>
      const FadeForwardsPageTransitionsBuilder().buildTransitions(
        this,
        context,
        kAlwaysCompleteAnimation,
        secondaryAnimation,
        child,
      ),
    PageTransitionStyle.slide => CupertinoPageTransition(
      primaryRouteAnimation: kAlwaysCompleteAnimation,
      secondaryRouteAnimation: secondaryAnimation,
      linearTransition: false,
      child: child,
    ),
    PageTransitionStyle.system => child,
  };
}

/// A shared-element page fades in and out over the still page below while
/// its Hero flies; nothing else moves, so the push, the back button and the
/// back gesture all read as the image travelling between its two spots.
///
/// The Android back gesture does not scrub the route: Heroes cannot follow
/// a gesture-driven pop (their start rect is fixed when it begins). It
/// shrinks the page with the finger instead, like the viewer's
/// drag-to-dismiss; a commit pops normally, so the Hero flies from the
/// shrunken image to its card and the page fades from where the gesture
/// left it. A cancel springs it back.
class _SharedElementTransition extends StatefulWidget {
  const _SharedElementTransition({
    required this.route,
    required this.animation,
    required this.child,
  });

  final PageRoute<dynamic> route;
  final Animation<double> animation;
  final Widget child;

  @override
  State<_SharedElementTransition> createState() =>
      _SharedElementTransitionState();
}

class _SharedElementTransitionState extends State<_SharedElementTransition>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// Material's predictive-back scale at full gesture progress.
  static const _gestureScale = 0.9;

  /// The back gesture's progress, 0 at rest.
  late final AnimationController _gesture = AnimationController(vsync: this);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gesture.dispose();
    super.dispose();
  }

  // The binding sends update, cancel and commit only to observers that
  // returned true from start.
  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final route = widget.route;
    if (defaultTargetPlatform != TargetPlatform.android ||
        backEvent.isButtonEvent ||
        !route.isCurrent ||
        !route.popGestureEnabled) {
      return false;
    }
    _gesture.value = backEvent.progress;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) =>
      _gesture.value = backEvent.progress;

  @override
  void handleCancelBackGesture() => unawaited(_settle());

  @override
  void handleCommitBackGesture() {
    final navigator = widget.route.navigator;
    if (navigator == null) return;
    unawaited(
      navigator.maybePop().then((popped) {
        // A PopScope that refused the pop leaves the page where it was.
        if (!popped && mounted) unawaited(_settle());
      }),
    );
  }

  Future<void> _settle() {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.spatialFast,
    );
    return _gesture.animateTo(0, duration: duration, curve: curve);
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: CurvedAnimation(
      parent: widget.animation,
      curve: MotionTokens.pageCurve,
    ),
    child: AnimatedBuilder(
      animation: _gesture,
      builder: (context, child) => Transform.scale(
        scale: 1 - (1 - _gestureScale) * _gesture.value,
        child: child,
      ),
      child: widget.child,
    ),
  );
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
