import 'package:animations/animations.dart'
    show SharedAxisPageTransitionsBuilder, SharedAxisTransitionType;
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransition;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart'
    show
        PredictiveBackPageTransitionsBuilder,
        Theme,
        ZoomPageTransitionsBuilder;

import '../../core/settings/app_settings.dart' show PageTransitionStyle;
import '../motion/motion_tokens.dart';
import '../motion/page_transitions.dart';
import '../widgets/branch_slide_stack.dart' show BranchActivityScope;

/// The app's standard route page, animated by [transitionStyle]:
/// - [PageTransitionStyle.system]: Android gets
///   [PredictiveBackPageTransitionsBuilder] (predictive-back shared element
///   on Android U+, FadeForwards elsewhere); every other platform keeps the
///   [FuncRouteTransition] trailing-edge slide.
/// - `sharedAxis`, `zoom`, `slide`: the official horizontal shared axis,
///   zoom and Cupertino slide transitions on every platform. On Android a
///   back-gesture driver lets the system back gesture scrub them.
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
      _page.transitionStyle == PageTransitionStyle.slide && !fullscreenDialog
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
      case PageTransitionStyle.sharedAxis:
        transition = (child) => SharedAxisPageTransitionsBuilder(
          transitionType: SharedAxisTransitionType.horizontal,
          fillColor: Theme.of(context).colorScheme.surface,
        ).buildTransitions(this, context, animation, secondaryAnimation, child);
      case PageTransitionStyle.zoom:
        transition = (child) =>
            const ZoomPageTransitionsBuilder().buildTransitions(
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
    final drive =
        android && _page.transitionStyle != PageTransitionStyle.system;
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

/// `CupertinoPageRoute`'s barrier over the page below a slide.
const _slideBarrierColor = Color(0x18000000);

/// Hands the Android predictive back gesture to [route] so a non-system
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
