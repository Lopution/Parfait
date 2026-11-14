import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransition;
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Theme;

import '../layout/app_breakpoints.dart';
import '../motion/hero_transition.dart'
    show HeroBarsCover, HeroLiftHole, HeroPageCover;
import '../motion/motion_tokens.dart';
import '../motion/page_transitions.dart';
import 'frozen_while_hidden.dart';
import 'home_shell_metrics.dart';
import 'route_animation.dart';

/// The app's standard route page, adapted per platform:
///
/// * **Android:** slides in from the trailing edge over a darkened, parallaxed
///   page below ([CupertinoPageTransition]) with [TurnCurve]; system back never
///   drives an in-app partial drag.
/// * **iOS:** same [CupertinoPageTransition], plus an interactive left-edge
///   (24dp zone) swipe-back gesture gated to the active visible route when
///   `canPop` holds (`PopScope` dirty-form protection still blocks it).
/// * **Desktop (Windows / macOS / Linux):** lightweight fade + subtle
///   horizontal slide (`MotionTokens.desktopPageTransition`).
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
    this.boundedOverlayOnWide = false,
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

  /// Whether wide flat viewports keep the underlying route visible behind
  /// a bounded detail overlay rather than obscuring it cleanly offstage.
  final bool boundedOverlayOnWide;

  @override
  Route<T> createRoute(BuildContext context) => _FuncPageRoute<T>(this);
}

class _FuncPageRoute<T> extends PageRoute<T> {
  _FuncPageRoute(FuncPage<T> page) : super(settings: page);

  FuncPage<T> get _page => settings as FuncPage<T>;

  /// Each route's page right above it, announced by that page as it is
  /// pushed or moved. A leaving page ignores later announcements, so
  /// through a pop this is still the page leaving; a disposed page clears
  /// its own entry. Keyed by any route: a page can sit on a route that is
  /// not a [FuncPage].
  static final _above = Expando<_FuncPageRoute<dynamic>>();

  /// The route this page last took as its [_above] key.
  Route<dynamic>? _below;

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
  late final Animation<double> _desktopMotion = TurnCurve.drive(
    animation!,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  late final Animation<double> _linearSlideIn = _GestureLinearAnimation(
    parent: animation!,
    curved: _slideIn,
    isDragging: () => _popGestureInProgress,
  );
  late final Animation<double> _linearSlideAside = _GestureLinearAnimation(
    parent: secondaryAnimation!,
    curved: _slideAside,
    isDragging: () => _popGestureInProgress,
  );

  final ValueNotifier<bool> _popGestureNotifier = ValueNotifier<bool>(false);
  _IosBackGestureController<T>? _activePopGesture;
  bool _routeDisposed = false;
  bool _boundedOverlayActive = false;

  bool get _popGestureInProgress => _activePopGesture != null;

  void _setActivePopGesture(_IosBackGestureController<T>? gesture) {
    _activePopGesture = gesture;
    if (_routeDisposed) return;
    final active = gesture != null;
    if (_popGestureNotifier.value == active) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_routeDisposed) {
          _popGestureNotifier.value = _activePopGesture != null;
        }
      });
      return;
    }
    _popGestureNotifier.value = active;
  }

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
    // A leaving page keeps the page it was on. When the page under it
    // leaves too (two backs in a row), the Navigator announces the page
    // below both to it; taking that would hand the leaving page's slide
    // to a page a shared-element page is leaving.
    if (!isActive) {
      super.didChangePrevious(previousRoute);
      return;
    }
    if (previousRoute != null) _above[previousRoute] = this;
    _below = previousRoute;
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
    _routeDisposed = true;
    _activePopGesture = null;
    _popGestureNotifier.dispose();
    _uncover();
    // A page removed without a pop never finished leaving: left behind, its
    // entry would hold the page below still for good.
    if (_below case final below? when identical(_above[below], this)) {
      _above[below] = null;
    }
    super.dispose();
  }

  @override
  bool get barrierDismissible => _page.barrierDismissible;

  AnimationController? get _routeController => controller;

  /// The slide darkens the page below like `CupertinoPageRoute`; a
  /// shared-element or bounded-overlay page leaves the page below as it is.
  @override
  Color? get barrierColor =>
      !fullscreenDialog && !_page.sharedElement && !_boundedOverlayActive
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
  bool get opaque => _boundedOverlayActive ? false : _page.opaque;

  bool _isBoundedOverlay(BuildContext context) =>
      _page.boundedOverlayOnWide &&
      !isFirst &&
      AppBreakpoints.useBoundedDetailOverlayOf(
        context,
        HomeShellChrome.contentSizeOf(context),
      );

  void _syncBoundedOverlay(bool active) {
    if (_boundedOverlayActive == active) return;
    _boundedOverlayActive = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_routeDisposed || overlayEntries.isEmpty) return;
      final targetOpaque = controller?.status == AnimationStatus.completed
          ? opaque
          : false;
      if (overlayEntries.first.opaque != targetOpaque) {
        overlayEntries.first.opaque = targetOpaque;
      }
      changedInternalState();
    });
  }

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
    final boundedOverlay = _isBoundedOverlay(context);
    if (_page.boundedOverlayOnWide) {
      _syncBoundedOverlay(boundedOverlay);
    }
    final shared = _page.sharedElement;
    final above = _above[this];
    final underBounded =
        above != null &&
        above._page.boundedOverlayOnWide &&
        !above.animation!.isDismissed &&
        AppBreakpoints.useBoundedDetailOverlayOf(
          context,
          HomeShellChrome.contentSizeOf(context),
        );
    final still = underSharedElement(this) || underBounded;
    final secondary = still ? kAlwaysDismissedAnimation : secondaryAnimation;
    final platform = Theme.of(context).platform;
    final isDesktop = switch (platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };

    if (isDesktop) {
      if (shared) {
        return FuncTransitionGuard(
          animation: animation,
          secondaryAnimation: secondary,
          transition: (child) => IgnorePointer(
            ignoring:
                animation.status == AnimationStatus.reverse ||
                _contentFade.value < 1,
            child: _sharedElementStage(context, child),
          ),
          child: child,
        );
      }
      if (!shared && boundedOverlay) {
        return FuncTransitionGuard(
          animation: animation,
          secondaryAnimation: secondary,
          transition: (child) => IgnorePointer(
            ignoring: animation.status == AnimationStatus.reverse,
            child: FadeTransition(opacity: _desktopMotion, child: child),
          ),
          child: child,
        );
      }
      final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
      final begin = rtl ? const Offset(-0.04, 0) : const Offset(0.04, 0);
      return FuncTransitionGuard(
        animation: animation,
        secondaryAnimation: secondary,
        transition: (child) => IgnorePointer(
          ignoring: animation.status == AnimationStatus.reverse,
          child: FadeTransition(
            opacity: _desktopMotion,
            child: SlideTransition(
              position: _desktopMotion.drive(
                Tween<Offset>(begin: begin, end: Offset.zero),
              ),
              child: child,
            ),
          ),
        ),
        child: child,
      );
    }

    if (platform == TargetPlatform.iOS) {
      if (!shared && boundedOverlay) {
        return FuncTransitionGuard(
          animation: animation,
          secondaryAnimation: secondary,
          transition: (child) => IgnorePointer(
            ignoring: animation.status == AnimationStatus.reverse,
            child: FadeTransition(opacity: _desktopMotion, child: child),
          ),
          child: child,
        );
      }
      return FuncTransitionGuard(
        animation: animation,
        secondaryAnimation: secondary,
        transition: (guardedChild) => ValueListenableBuilder<bool>(
          valueListenable: _popGestureNotifier,
          child: guardedChild,
          builder: (context, popGestureInProgress, builtChild) {
            final content = shared
                ? _sharedElementStage(
                    context,
                    builtChild!,
                    popGestureInProgress: popGestureInProgress,
                  )
                : builtChild!;
            return IgnorePointer(
              // Leaving, nothing of the page takes a touch, so the page below
              // answers at once: while the image flies home, and where the
              // sliding page still is. Opening, a shared-element page takes
              // none until its content has shown.
              ignoring:
                  animation.status == AnimationStatus.reverse ||
                  shared && !popGestureInProgress && _contentFade.value < 1,
              // On iOS we attach our own 24dp edge-back detector inside
              // CupertinoPageTransition (instead of CupertinoPageTransitionsBuilder)
              // so horizontal drags inside DetailImagePager/PageView stay intact.
              child: CupertinoPageTransition(
                primaryRouteAnimation: shared && !popGestureInProgress
                    ? kAlwaysCompleteAnimation
                    : _linearSlideIn,
                secondaryRouteAnimation: still
                    ? kAlwaysDismissedAnimation
                    : _linearSlideAside,
                linearTransition: true,
                child: _IosEdgeBackDetector<T>(route: this, child: content),
              ),
            );
          },
        ),
        child: child,
      );
    }

    return FuncTransitionGuard(
      animation: animation,
      secondaryAnimation: secondary,
      transition: (child) {
        if (!shared && boundedOverlay) {
          return IgnorePointer(
            ignoring: animation.status == AnimationStatus.reverse,
            child: FadeTransition(opacity: _desktopMotion, child: child),
          );
        }
        return IgnorePointer(
          ignoring:
              animation.status == AnimationStatus.reverse ||
              shared && _contentFade.value < 1,
          child: CupertinoPageTransition(
            primaryRouteAnimation: shared ? kAlwaysCompleteAnimation : _slideIn,
            secondaryRouteAnimation: still
                ? kAlwaysDismissedAnimation
                : _slideAside,
            linearTransition: true,
            child: shared ? _sharedElementStage(context, child) : child,
          ),
        );
      },
      child: child,
    );
  }

  Widget _sharedElementStage(
    BuildContext context,
    Widget child, {
    bool popGestureInProgress = false,
  }) {
    final content = FadeTransition(
      opacity: popGestureInProgress ? kAlwaysCompleteAnimation : _contentFade,
      child: HeroLiftHole(animation: controller!, child: child),
    );
    if (!_backdrop || _isBoundedOverlay(context)) return content;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: FadeTransition(
            opacity: popGestureInProgress
                ? kAlwaysCompleteAnimation
                : _backdropFade,
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

/// Switches between the curved route animation and linear 1:1 tracking while
/// an interactive iOS edge swipe-back is active.
class _GestureLinearAnimation extends Animation<double>
    with AnimationWithParentMixin<double> {
  _GestureLinearAnimation({
    required this.parent,
    required this.curved,
    required this.isDragging,
  });

  @override
  final Animation<double> parent;
  final Animation<double> curved;
  final ValueGetter<bool> isDragging;

  @override
  double get value => isDragging() ? parent.value : curved.value;
}

const double _kIosBackEdgeWidth = 24.0;
const double _kMinFlingVelocity = 1.0;

class _IosEdgeBackDetector<T> extends StatefulWidget {
  const _IosEdgeBackDetector({required this.route, required this.child});

  final _FuncPageRoute<T> route;
  final Widget child;

  @override
  State<_IosEdgeBackDetector<T>> createState() =>
      _IosEdgeBackDetectorState<T>();
}

class _IosEdgeBackDetectorState<T> extends State<_IosEdgeBackDetector<T>> {
  _IosBackGestureController<T>? _backGestureController;
  late final _InwardHorizontalDragGestureRecognizer _recognizer =
      _InwardHorizontalDragGestureRecognizer(debugOwner: this)
        ..onStart = _handleDragStart
        ..onUpdate = _handleDragUpdate
        ..onEnd = _handleDragEnd
        ..onCancel = _handleDragCancel;

  bool get _enabled {
    final route = widget.route;
    if (Theme.of(context).platform != TargetPlatform.iOS) return false;
    if (route.fullscreenDialog || !route.isCurrent) return false;
    if (!route.popGestureEnabled) return false;
    if (!TickerMode.getValuesNotifier(context).value.enabled) return false;
    if (route.navigator?.userGestureInProgress ?? true) return false;
    return true;
  }

  @override
  void dispose() {
    _recognizer.dispose();
    if (_backGestureController case final active?) {
      _backGestureController = null;
      active.cancelOnDispose();
    }
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_enabled) return;
    _recognizer.inwardSign = Directionality.of(context) == TextDirection.rtl
        ? -1.0
        : 1.0;
    _recognizer.addPointer(event);
  }

  void _handleDragStart(DragStartDetails details) {
    if (!_enabled) return;
    final route = widget.route;
    final navigator = route.navigator;
    final controller = route._routeController;
    if (navigator == null || controller == null) return;
    late final _IosBackGestureController<T> gestureController;
    gestureController = _IosBackGestureController<T>(
      navigator: navigator,
      controller: controller,
      getIsCurrent: () => route.isCurrent,
      getIsActive: () => route.isActive,
      dropDuration: MotionTokens.resolve(context, MotionTokens.chrome),
      onFinished: () {
        if (identical(_backGestureController, gestureController)) {
          _backGestureController = null;
        }
        if (identical(route._activePopGesture, gestureController)) {
          route._setActivePopGesture(null);
        }
      },
    );
    _backGestureController = gestureController;
    route._setActivePopGesture(gestureController);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final active = _backGestureController;
    final width = context.size?.width ?? 0;
    if (active == null || width <= 0) return;
    active.dragUpdate(_convertToLogical(details.primaryDelta! / width));
  }

  void _handleDragEnd(DragEndDetails details) {
    final active = _backGestureController;
    final width = context.size?.width ?? 0;
    if (active == null) return;
    final velocity = width > 0
        ? _convertToLogical(details.velocity.pixelsPerSecond.dx / width)
        : 0.0;
    active.dragEnd(velocity);
  }

  void _handleDragCancel() {
    final active = _backGestureController;
    if (active == null) return;
    active.dragEnd(0.0);
  }

  double _convertToLogical(double value) =>
      switch (Directionality.of(context)) {
        TextDirection.rtl => -value,
        TextDirection.ltr => value,
      };

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final edgePadding = switch (Directionality.of(context)) {
      TextDirection.rtl => padding.right,
      TextDirection.ltr => padding.left,
    };
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        PositionedDirectional(
          start: 0,
          width: math.max(edgePadding, _kIosBackEdgeWidth),
          top: 0,
          bottom: 0,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _handlePointerDown,
          ),
        ),
      ],
    );
  }
}

/// Only competes for drags moving inward from the screen's leading edge, so
/// an outward swipe inside a pager at the edge stays with the pager.
class _InwardHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  _InwardHorizontalDragGestureRecognizer({super.debugOwner});

  double inwardSign = 1.0;
  double? _startX;
  bool _decided = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _startX = event.position.dx;
    _decided = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (!_decided && _startX != null && event is PointerMoveEvent) {
      final dx = (event.position.dx - _startX!) * inwardSign;
      final slop = gestureSettings?.touchSlop ?? kTouchSlop;
      if (dx < -slop * 0.5) {
        _decided = true;
        resolve(GestureDisposition.rejected);
        return;
      }
      if (dx > slop) {
        _decided = true;
      }
    }
    super.handleEvent(event);
  }
}

class _IosBackGestureController<T> {
  _IosBackGestureController({
    required this.navigator,
    required this.controller,
    required this.getIsActive,
    required this.getIsCurrent,
    required this.dropDuration,
    required this.onFinished,
  }) {
    navigator.didStartUserGesture();
  }

  final AnimationController controller;
  final NavigatorState navigator;
  final ValueGetter<bool> getIsActive;
  final ValueGetter<bool> getIsCurrent;
  final Duration dropDuration;
  final VoidCallback onFinished;

  AnimationStatusListener? _statusListener;
  bool _dragEnded = false;
  bool _finished = false;

  void dragUpdate(double delta) {
    if (_dragEnded || _finished) return;
    controller.value -= delta;
  }

  void dragEnd(double velocity) {
    if (_dragEnded || _finished) return;
    _dragEnded = true;
    const animationCurve = Curves.fastEaseInToSlowEaseOut;
    final isCurrent = getIsCurrent();
    final bool animateForward;
    if (!isCurrent) {
      animateForward = getIsActive();
    } else if (velocity.abs() >= _kMinFlingVelocity) {
      animateForward = velocity <= 0;
    } else {
      animateForward = controller.value > 0.5;
    }

    if (animateForward) {
      if (dropDuration == Duration.zero) {
        controller.value = 1.0;
      } else {
        controller.animateTo(
          1.0,
          duration: dropDuration,
          curve: animationCurve,
        );
      }
    } else {
      if (isCurrent) {
        navigator.pop();
      }
      if (controller.isAnimating) {
        if (dropDuration == Duration.zero) {
          controller.value = 0.0;
        } else {
          controller.animateBack(
            0.0,
            duration: dropDuration,
            curve: animationCurve,
          );
        }
      }
    }

    if (controller.isAnimating) {
      _statusListener = (AnimationStatus status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          _complete();
        }
      };
      controller.addStatusListener(_statusListener!);
    } else {
      _complete();
    }
  }

  void cancelOnDispose() {
    if (_finished) return;
    _finished = true;
    _detachListener();
    onFinished();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted) {
        navigator.didStopUserGesture();
      }
    });
  }

  void _complete() {
    if (_finished) return;
    _finished = true;
    _detachListener();
    onFinished();
    if (navigator.mounted) {
      navigator.didStopUserGesture();
    }
  }

  void _detachListener() {
    if (_statusListener case final listener?) {
      _statusListener = null;
      controller.removeStatusListener(listener);
    }
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
