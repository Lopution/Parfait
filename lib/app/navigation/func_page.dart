import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart'
    show PredictiveBackPageTransitionsBuilder;

import '../motion/motion_tokens.dart';
import '../motion/page_transitions.dart';

/// The app's standard route page: Android gets the system transition —
/// [PredictiveBackPageTransitionsBuilder] (predictive-back shared element
/// on Android U+, FadeForwards elsewhere) — every other platform keeps the
/// [FuncRouteTransition] trailing-edge slide.
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

  @override
  Route<T> createRoute(BuildContext context) => _FuncPageRoute<T>(this);
}

class _FuncPageRoute<T> extends PageRoute<T> {
  _FuncPageRoute(FuncPage<T> page) : super(settings: page);

  FuncPage<T> get _page => settings as FuncPage<T>;

  @override
  bool get barrierDismissible => _page.barrierDismissible;

  @override
  Color? get barrierColor => _page.barrierColor;

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
    // FuncRouteTransition carries its own guard; only the Android path
    // composes the shared guard around the platform builder.
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => FuncTransitionGuard(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        transition: (child) =>
            const PredictiveBackPageTransitionsBuilder().buildTransitions(
              this,
              context,
              animation,
              secondaryAnimation,
              child,
            ),
        child: child,
      ),
      _ => FuncRouteTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      ),
    };
  }
}
