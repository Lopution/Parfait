import 'dart:math' as math;
import 'dart:ui' as ui show lerpDouble;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageTransition;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Theme;

import '../layout/app_breakpoints.dart';
import '../motion/hero_transition.dart'
    show HeroBarsCover, HeroLiftHole, HeroPageCover;
import '../motion/motion_tokens.dart';
import '../motion/page_transitions.dart';
import '../theme/func_semantic_tokens.dart' show FuncShape;
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
///   `canPop` holds (`PopScope` dirty-form protection still blocks it). Full-screen
///   shared-element detail routes widen the leading edge and accept downward
///   pulls from the top strip or top-rested scrollables, fading the backdrop and
///   applying damped canvas scaling/displacement into the Hero return flight.
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

  /// Whether [route] is currently presented as a wide bounded overlay over a
  /// visible underlying route rather than covering the full page.
  static bool isBoundedOverlayRoute(Route<dynamic>? route) =>
      route is _FuncPageRoute && route._boundedOverlayActive;

  /// Whether [route] has an active iOS shared-element canvas drag/shrink
  /// displacement, meaning the underlying page and its bars are already
  /// exposed behind the translucent backdrop.
  static bool hasCanvasDragOffset(Route<dynamic>? route) =>
      route is _FuncPageRoute &&
      (route._canvasDrag.value.progress > 0 ||
          route._canvasBackdropFactor.value < 1.0);

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
  final ValueNotifier<_CanvasDragState> _canvasDrag =
      ValueNotifier<_CanvasDragState>(_CanvasDragState.zero);
  final ValueNotifier<double> _canvasBackdropFactor = ValueNotifier<double>(
    1.0,
  );
  _IosBackGestureController<T>? _activePopGesture;
  _IosCanvasDismissController<T>? _activeCanvasDismiss;
  bool _routeDisposed = false;
  bool _boundedOverlayActive = false;

  bool get _popGestureInProgress =>
      _activePopGesture != null || _activeCanvasDismiss != null;

  bool _supportsCanvasDismiss(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.iOS &&
      _page.sharedElement &&
      _backdrop &&
      !_isBoundedOverlay(context);

  void _syncPopGestureNotifier() {
    if (_routeDisposed) return;
    final active = _popGestureInProgress;
    if (_popGestureNotifier.value == active) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_routeDisposed) {
          _popGestureNotifier.value = _popGestureInProgress;
        }
      });
      return;
    }
    _popGestureNotifier.value = active;
  }

  void _setActivePopGesture(_IosBackGestureController<T>? gesture) {
    _activePopGesture = gesture;
    _syncPopGestureNotifier();
  }

  bool get _revealingBelow =>
      _activeCanvasDismiss != null || _canvasDrag.value.progress > 0;

  void _setActiveCanvasDismiss(_IosCanvasDismissController<T>? gesture) {
    _activeCanvasDismiss = gesture;
    _syncPopGestureNotifier();
    _syncRouteOpacity();
  }

  void _setCanvasDrag(
    _CanvasDragState state, {
    required double backdropFactor,
  }) {
    if (_routeDisposed) return;
    _canvasDrag.value = state;
    _canvasBackdropFactor.value = backdropFactor;
    _syncRouteOpacity();
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

  /// Combines [_backdropFade] with interactive drag transparency so dragging
  /// a shared-element detail route reveals the underlying page smoothly and
  /// hands off to reverse playback without snapping opaque.
  late final Animation<double> _interactiveBackdropFade = _MultipliedAnimation(
    base: _backdropFade,
    factor: _canvasBackdropFactor,
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
          curve: const _Primed(MotionTokens.sharedElementFadeIn),
          reverseCurve: Curves.easeInOutCubic,
        );

  /// Full-cycle fade for a wide bounded detail overlay (`DetailOverlayFrame`),
  /// so its scrim and modal card ease in from frame 1 instead of staying
  /// transparent for the first 30% (135ms) of the Hero flight.
  late final Animation<double> _boundedOverlayFade = TurnCurve.drive(
    controller!,
    curve: const _Primed(Curves.easeOutCubic),
    reverseCurve: Curves.easeInCubic,
  );

  late final Animation<double> _heroPageCoverOpacity = _BoundedSwitchAnimation(
    bounded: () => _boundedOverlayActive,
    whenBounded: _boundedOverlayFade,
    whenFullPage: _backdrop ? _interactiveBackdropFade : _contentFade,
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
        // What hides the page below: the background where there is one, or
        // the full-cycle scrim fade on a wide bounded overlay.
        HeroPageCover.add(previousRoute, this, _heroPageCoverOpacity);
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
    _activeCanvasDismiss = null;
    _popGestureNotifier.dispose();
    _canvasDrag.dispose();
    _canvasBackdropFactor.dispose();
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
  bool get opaque =>
      _boundedOverlayActive || _revealingBelow ? false : _page.opaque;

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
      _syncRouteOpacity(forceChangedState: true);
    });
  }

  void _syncRouteOpacity({bool forceChangedState = false}) {
    if (_routeDisposed || overlayEntries.isEmpty) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncRouteOpacity(forceChangedState: forceChangedState);
      });
      return;
    }
    final targetOpaque = controller?.status == AnimationStatus.completed
        ? opaque
        : false;
    final entry = overlayEntries.first;
    final changed = entry.opaque != targetOpaque;
    if (changed) {
      entry.opaque = targetOpaque;
    }
    if (changed || forceChangedState) {
      changedInternalState();
    }
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    Widget page = RouteAnimationScope(
      // The controller: [animation] reads complete while a Hero measures
      // the opening page (see RouteAnimationScope).
      animation: controller!,
      popGesture: _popGestureNotifier,
      child: Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        child: FrozenWhileHidden(child: _page.child),
      ),
    );
    if (_supportsCanvasDismiss(context)) {
      final reduceMotion = !MotionTokens.enabled(context);
      // Keep the interactive drag translation/scale inside [subtreeContext]
      // so HeroController measures the shrunken canvas rect on commit pop
      // instead of snapping back to the untransformed 1.0x origin.
      page = ValueListenableBuilder<_CanvasDragState>(
        valueListenable: _canvasDrag,
        child: page,
        builder: (context, drag, inner) {
          final hasMotionDrag = !reduceMotion && drag.progress > 0;
          return Transform.translate(
            offset: reduceMotion ? Offset.zero : drag.offset,
            child: Transform.scale(
              scale: reduceMotion ? 1.0 : drag.scale,
              alignment: Alignment.center,
              child: ClipRRect(
                key: const ValueKey('func-shared-canvas-clip'),
                clipBehavior: hasMotionDrag ? Clip.antiAlias : Clip.none,
                borderRadius: hasMotionDrag
                    ? BorderRadius.lerp(
                        BorderRadius.zero,
                        FuncShape.dialog,
                        drag.progress.clamp(0.0, 1.0),
                      )!
                    : BorderRadius.zero,
                child: inner,
              ),
            ),
          );
        },
      );
    }
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
    final stageFade = boundedOverlay ? _boundedOverlayFade : _contentFade;
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
                stageFade.value < 1,
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
      final canvasDismiss = _supportsCanvasDismiss(context);
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
                    supportsCanvasDismiss: canvasDismiss,
                  )
                : boundedOverlay
                ? FadeTransition(
                    opacity: popGestureInProgress
                        ? kAlwaysCompleteAnimation
                        : _desktopMotion,
                    child: builtChild!,
                  )
                : builtChild!;
            return IgnorePointer(
              // Leaving, nothing of the page takes a touch, so the page below
              // answers at once: while the image flies home, and where the
              // sliding page still is. Opening, a shared-element page takes
              // none until its content has shown.
              ignoring:
                  animation.status == AnimationStatus.reverse ||
                  shared && !popGestureInProgress && stageFade.value < 1,
              // On iOS we attach our own edge-back/canvas-dismiss detector inside
              // CupertinoPageTransition (instead of CupertinoPageTransitionsBuilder)
              // so horizontal drags inside DetailImagePager/PageView stay intact.
              // Wide bounded overlays keep the outer page stationary so
              // DetailOverlayFrame can fade its scrim in place while sliding
              // only the foreground card.
              child: CupertinoPageTransition(
                primaryRouteAnimation:
                    boundedOverlay ||
                        (shared && (canvasDismiss || !popGestureInProgress))
                    ? kAlwaysCompleteAnimation
                    : _linearSlideIn,
                secondaryRouteAnimation: still
                    ? kAlwaysDismissedAnimation
                    : _linearSlideAside,
                linearTransition: true,
                child: _IosEdgeBackDetector<T>(
                  route: this,
                  supportsCanvasDismiss: canvasDismiss,
                  child: content,
                ),
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
              shared && stageFade.value < 1,
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
    bool supportsCanvasDismiss = false,
  }) {
    final boundedOverlay = _isBoundedOverlay(context);
    final content = FadeTransition(
      opacity: !supportsCanvasDismiss && popGestureInProgress
          ? kAlwaysCompleteAnimation
          : boundedOverlay
          ? _boundedOverlayFade
          : _contentFade,
      child: HeroLiftHole(animation: controller!, child: child),
    );
    if (!_backdrop || boundedOverlay) return content;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: FadeTransition(
            opacity: !supportsCanvasDismiss && popGestureInProgress
                ? kAlwaysCompleteAnimation
                : _interactiveBackdropFade,
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
const double _kSharedIosBackEdgeWidth = 48.0;
const double _kSharedTopPullHeight = 72.0;
const double _kMinFlingVelocity = 1.0;
const double _kCanvasCommitFlingVelocity = 500.0;
const double _kCanvasCancelFlingVelocity = -200.0;
const double _kCanvasCommitProgress = 0.35;
const double _kCanvasMinScale = 0.85;
const double _kCanvasMinBackdropFactor = 0.12;

@immutable
class _CanvasDragState {
  const _CanvasDragState({
    required this.offset,
    required this.scale,
    required this.progress,
  });

  static const zero = _CanvasDragState(
    offset: Offset.zero,
    scale: 1.0,
    progress: 0.0,
  );

  final Offset offset;
  final double scale;
  final double progress;

  static _CanvasDragState lerp(
    _CanvasDragState a,
    _CanvasDragState b,
    double t,
  ) => _CanvasDragState(
    offset: Offset.lerp(a.offset, b.offset, t) ?? Offset.zero,
    scale: ui.lerpDouble(a.scale, b.scale, t) ?? 1.0,
    progress: ui.lerpDouble(a.progress, b.progress, t) ?? 0.0,
  );
}

class _MultipliedAnimation extends Animation<double>
    with
        AnimationLazyListenerMixin,
        AnimationLocalListenersMixin,
        AnimationLocalStatusListenersMixin {
  _MultipliedAnimation({required this.base, required this.factor});

  final Animation<double> base;
  final ValueListenable<double> factor;

  @override
  void didStartListening() {
    base.addListener(notifyListeners);
    factor.addListener(notifyListeners);
    base.addStatusListener(notifyStatusListeners);
  }

  @override
  void didStopListening() {
    base.removeListener(notifyListeners);
    factor.removeListener(notifyListeners);
    base.removeStatusListener(notifyStatusListeners);
  }

  @override
  AnimationStatus get status => base.status;

  @override
  double get value => (base.value * factor.value).clamp(0.0, 1.0);
}

class _BoundedSwitchAnimation extends Animation<double>
    with
        AnimationLazyListenerMixin,
        AnimationLocalListenersMixin,
        AnimationLocalStatusListenersMixin {
  _BoundedSwitchAnimation({
    required this.bounded,
    required this.whenBounded,
    required this.whenFullPage,
  });

  final ValueGetter<bool> bounded;
  final Animation<double> whenBounded;
  final Animation<double> whenFullPage;

  @override
  void didStartListening() {
    whenBounded.addListener(notifyListeners);
    whenFullPage.addListener(notifyListeners);
    whenBounded.addStatusListener(notifyStatusListeners);
  }

  @override
  void didStopListening() {
    whenBounded.removeListener(notifyListeners);
    whenFullPage.removeListener(notifyListeners);
    whenBounded.removeStatusListener(notifyStatusListeners);
  }

  @override
  AnimationStatus get status =>
      bounded() ? whenBounded.status : whenFullPage.status;

  @override
  double get value => bounded() ? whenBounded.value : whenFullPage.value;
}

class _IosEdgeBackDetector<T> extends StatefulWidget {
  const _IosEdgeBackDetector({
    required this.route,
    this.supportsCanvasDismiss = false,
    required this.child,
  });

  final _FuncPageRoute<T> route;
  final bool supportsCanvasDismiss;
  final Widget child;

  @override
  State<_IosEdgeBackDetector<T>> createState() =>
      _IosEdgeBackDetectorState<T>();
}

class _IosEdgeBackDetectorState<T> extends State<_IosEdgeBackDetector<T>>
    with SingleTickerProviderStateMixin {
  _IosBackGestureController<T>? _backGestureController;
  _IosCanvasDismissController<T>? _canvasDismissController;
  bool _verticalScrollAtTop = true;
  int? _settledHorizontalPage;

  late final AnimationController _returnController = AnimationController(
    vsync: this,
  );
  late final _InwardHorizontalDragGestureRecognizer _recognizer =
      _InwardHorizontalDragGestureRecognizer(debugOwner: this)
        ..onStart = _handleEdgeDragStart
        ..onUpdate = _handleEdgeDragUpdate
        ..onEnd = _handleEdgeDragEnd
        ..onCancel = _handleEdgeDragCancel;
  late final _DownwardVerticalDragGestureRecognizer _verticalRecognizer =
      _DownwardVerticalDragGestureRecognizer(debugOwner: this)
        ..onStart = _handleVerticalDragStart
        ..onUpdate = _handleVerticalDragUpdate
        ..onEnd = _handleVerticalDragEnd
        ..onCancel = _handleVerticalDragCancel;

  bool get _enabled {
    final route = widget.route;
    if (Theme.of(context).platform != TargetPlatform.iOS) return false;
    if (route.fullscreenDialog || !route.isCurrent || !route.isActive) {
      return false;
    }
    if (route._routeController?.status == AnimationStatus.reverse) {
      return false;
    }
    if (!route.popGestureEnabled) return false;
    if (!TickerMode.getValuesNotifier(context).value.enabled) return false;
    if (route.navigator?.userGestureInProgress ?? true) return false;
    if (route._popGestureInProgress) return false;
    return true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final gestureSettings = MediaQuery.maybeGestureSettingsOf(context);
    _recognizer.gestureSettings = gestureSettings;
    _verticalRecognizer.gestureSettings = gestureSettings;
  }

  @override
  void dispose() {
    _recognizer.dispose();
    _verticalRecognizer.dispose();
    if (_backGestureController case final active?) {
      _backGestureController = null;
      active.cancelOnDispose();
    }
    if (_canvasDismissController case final canvas?) {
      _canvasDismissController = null;
      canvas.cancelOnDispose();
    }
    _returnController.dispose();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_enabled) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = box.globalToLocal(event.position);
    final width = box.size.width;
    final padding = MediaQuery.paddingOf(context);
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final edgePadding = isRtl ? padding.right : padding.left;
    final baseEdgeWidth = widget.supportsCanvasDismiss
        ? _kSharedIosBackEdgeWidth
        : _kIosBackEdgeWidth;
    final edgeWidth = math.max(edgePadding, baseEdgeWidth);
    final inwardDistance = isRtl ? width - local.dx : local.dx;

    final gestureSettings = MediaQuery.maybeGestureSettingsOf(context);
    if (inwardDistance >= 0 && inwardDistance <= edgeWidth) {
      _recognizer
        ..gestureSettings = gestureSettings
        ..inwardSign = isRtl ? -1.0 : 1.0
        ..addPointer(event);
    }

    if (widget.supportsCanvasDismiss) {
      final inTopStrip =
          local.dy >= 0 && local.dy <= padding.top + _kSharedTopPullHeight;
      if (inTopStrip || _verticalScrollAtTop) {
        _verticalRecognizer
          ..gestureSettings = gestureSettings
          ..addPointer(event);
      }
    }
  }

  void _startCanvasDismiss({required bool vertical}) {
    if (!_enabled || _canvasDismissController != null) return;
    final route = widget.route;
    final navigator = route.navigator;
    final controller = route._routeController;
    final size = context.size ?? MediaQuery.sizeOf(context);
    if (navigator == null || controller == null || size.isEmpty) return;
    final (returnDuration, returnCurve) = MotionTokens.springCurve(
      context,
      MotionSpring.spatialFast,
    );
    late final _IosCanvasDismissController<T> canvasController;
    canvasController = _IosCanvasDismissController<T>(
      route: route,
      navigator: navigator,
      controller: controller,
      returnController: _returnController,
      returnDuration: returnDuration,
      returnCurve: returnCurve,
      viewport: size,
      isVertical: vertical,
      isRtl: Directionality.of(context) == TextDirection.rtl,
      getIsCurrent: () => route.isCurrent,
      onFinished: () {
        if (identical(_canvasDismissController, canvasController)) {
          _canvasDismissController = null;
        }
        if (identical(route._activeCanvasDismiss, canvasController)) {
          route._setActiveCanvasDismiss(null);
        }
      },
    );
    _canvasDismissController = canvasController;
    route._setActiveCanvasDismiss(canvasController);
  }

  void _handleEdgeDragStart(DragStartDetails details) {
    if (!_enabled) return;
    if (widget.supportsCanvasDismiss) {
      _startCanvasDismiss(vertical: false);
      return;
    }
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

  void _handleEdgeDragUpdate(DragUpdateDetails details) {
    final canvas = _canvasDismissController;
    if (canvas != null && !canvas.isVertical) {
      canvas.dragUpdate(Offset(_convertToLogical(details.primaryDelta!), 0));
      return;
    }
    final active = _backGestureController;
    final width = context.size?.width ?? 0;
    if (active == null || width <= 0) return;
    active.dragUpdate(_convertToLogical(details.primaryDelta! / width));
  }

  void _handleEdgeDragEnd(DragEndDetails details) {
    final canvas = _canvasDismissController;
    if (canvas != null && !canvas.isVertical) {
      canvas.dragEnd(_convertToLogical(details.velocity.pixelsPerSecond.dx));
      return;
    }
    final active = _backGestureController;
    final width = context.size?.width ?? 0;
    if (active == null) return;
    final velocity = width > 0
        ? _convertToLogical(details.velocity.pixelsPerSecond.dx / width)
        : 0.0;
    active.dragEnd(velocity);
  }

  void _handleEdgeDragCancel() {
    final canvas = _canvasDismissController;
    if (canvas != null && !canvas.isVertical) {
      canvas.dragEnd(0.0);
      return;
    }
    final active = _backGestureController;
    if (active == null) return;
    active.dragEnd(0.0);
  }

  void _handleVerticalDragStart(DragStartDetails details) {
    if (!widget.supportsCanvasDismiss) return;
    _startCanvasDismiss(vertical: true);
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    final canvas = _canvasDismissController;
    if (canvas == null || !canvas.isVertical) return;
    canvas.dragUpdate(Offset(0, details.primaryDelta!));
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    final canvas = _canvasDismissController;
    if (canvas == null || !canvas.isVertical) return;
    canvas.dragEnd(details.velocity.pixelsPerSecond.dy);
  }

  void _handleVerticalDragCancel() {
    final canvas = _canvasDismissController;
    if (canvas == null || !canvas.isVertical) return;
    canvas.dragEnd(0.0);
  }

  double _convertToLogical(double value) =>
      switch (Directionality.of(context)) {
        TextDirection.rtl => -value,
        TextDirection.ltr => value,
      };

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis == Axis.vertical) {
      if (notification is ScrollStartNotification ||
          notification is ScrollUpdateNotification ||
          notification is ScrollEndNotification) {
        _verticalScrollAtTop =
            notification.metrics.pixels <=
            notification.metrics.minScrollExtent + 0.5;
      }
    } else if (notification.depth == 0 && notification.metrics is PageMetrics) {
      final page = (notification.metrics as PageMetrics).page?.round();
      if (notification is ScrollStartNotification) {
        _settledHorizontalPage ??= page;
      } else if (notification is ScrollEndNotification && page != null) {
        // Only reset vertical scroll state when the pager actually settled on
        // a different artwork; a slight horizontal nudge snapping back to the
        // same scrolled-down work must not arm vertical canvas dismiss.
        final previous = _settledHorizontalPage;
        _settledHorizontalPage = page;
        if (previous != null && page != previous) {
          _verticalScrollAtTop = true;
        }
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.supportsCanvasDismiss
        ? NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: widget.child,
          )
        : widget.child;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        content,
        Positioned.fill(
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
/// an outward swipe inside a pager or vertical scroll at the edge stays free.
class _InwardHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  _InwardHorizontalDragGestureRecognizer({super.debugOwner});

  double inwardSign = 1.0;
  Offset? _startPosition;
  bool _decided = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _startPosition = event.position;
    _decided = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (!_decided && _startPosition != null && event is PointerMoveEvent) {
      final delta = event.position - _startPosition!;
      final dx = delta.dx * inwardSign;
      final absDy = delta.dy.abs();
      final slop = gestureSettings?.touchSlop ?? kTouchSlop;
      if (dx < -slop * 0.5 || (absDy > slop * 0.5 && dx < absDy * 1.1)) {
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

/// Only competes for predominantly downward pulls, rejecting immediately on
/// upward scrolls or horizontal pager swipes so [CustomScrollView] and
/// [PageView] / [DetailImagePager] never lose responsiveness.
class _DownwardVerticalDragGestureRecognizer
    extends VerticalDragGestureRecognizer {
  _DownwardVerticalDragGestureRecognizer({super.debugOwner});

  Offset? _startPosition;
  bool _decided = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _startPosition = event.position;
    _decided = false;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (!_decided && _startPosition != null && event is PointerMoveEvent) {
      final delta = event.position - _startPosition!;
      final dy = delta.dy;
      final absDx = delta.dx.abs();
      final slop = gestureSettings?.touchSlop ?? kTouchSlop;
      if (dy < -slop * 0.5 || (absDx > slop * 0.5 && dy < absDx * 1.35)) {
        _decided = true;
        resolve(GestureDisposition.rejected);
        return;
      }
      if (dy > slop) {
        _decided = true;
      }
    }
    super.handleEvent(event);
  }
}

class _IosCanvasDismissController<T> {
  _IosCanvasDismissController({
    required this.route,
    required this.navigator,
    required this.controller,
    required this.returnController,
    required this.returnDuration,
    required this.returnCurve,
    required this.viewport,
    required this.isVertical,
    required this.isRtl,
    required this.getIsCurrent,
    required this.onFinished,
  }) : _dismissExtent = math.max(
         120.0,
         math.min(viewport.width, viewport.height) * 0.45,
       ) {
    navigator.didStartUserGesture();
  }

  final _FuncPageRoute<T> route;
  final NavigatorState navigator;
  final AnimationController controller;
  final AnimationController returnController;
  final Duration returnDuration;
  final Curve returnCurve;
  final Size viewport;
  final bool isVertical;
  final bool isRtl;
  final ValueGetter<bool> getIsCurrent;
  final VoidCallback onFinished;
  final double _dismissExtent;

  Offset _rawDelta = Offset.zero;
  _CanvasDragState _currentState = _CanvasDragState.zero;
  double _currentBackdropFactor = 1.0;
  AnimationStatusListener? _routeStatusListener;
  VoidCallback? _returnTickListener;
  AnimationStatusListener? _returnStatusListener;
  bool _dragEnded = false;
  bool _finished = false;

  void dragUpdate(Offset logicalDelta) {
    if (_dragEnded || _finished) return;
    _rawDelta += logicalDelta;
    final distance = isVertical
        ? math.max(0.0, _rawDelta.dy)
        : math.max(0.0, _rawDelta.dx);
    final progress = (distance / _dismissExtent).clamp(0.0, 1.0);
    final eased = Curves.easeOut.transform(progress);
    final scale = ui.lerpDouble(1.0, _kCanvasMinScale, eased)!;
    final visualOffset = isVertical
        ? Offset(0, _dampedVertical(_rawDelta.dy))
        : Offset(_visualX(_rawDelta.dx * 0.45), 0);
    _currentState = _CanvasDragState(
      offset: visualOffset,
      scale: scale,
      progress: progress,
    );
    _currentBackdropFactor = (1.0 - progress * 0.85).clamp(
      _kCanvasMinBackdropFactor,
      1.0,
    );
    route._setCanvasDrag(_currentState, backdropFactor: _currentBackdropFactor);
  }

  double _dampedVertical(double dy) => dy >= 0 ? dy * 0.55 : dy * 0.15;

  double _visualX(double logicalX) => isRtl ? -logicalX : logicalX;

  void dragEnd(double primaryVelocity) {
    if (_dragEnded || _finished) return;
    _dragEnded = true;
    final isCurrent = getIsCurrent();
    final shouldCommit =
        isCurrent &&
        (primaryVelocity >= _kCanvasCommitFlingVelocity ||
            (primaryVelocity > _kCanvasCancelFlingVelocity &&
                _currentState.progress >= _kCanvasCommitProgress));

    if (shouldCommit) {
      route._setCanvasDrag(
        _currentState,
        backdropFactor: _currentBackdropFactor,
      );
      // End the user gesture before popping so HeroController.didChangeTop
      // triggers the return flight from the dragged canvas rect.
      _complete();
      navigator.pop();
      return;
    }

    if (returnDuration == Duration.zero) {
      route._setCanvasDrag(_CanvasDragState.zero, backdropFactor: 1.0);
      _complete();
      return;
    }

    final startState = _currentState;
    final startFactor = _currentBackdropFactor;
    _returnTickListener = () {
      if (_finished) return;
      final t = returnCurve.transform(returnController.value);
      route._setCanvasDrag(
        _CanvasDragState.lerp(startState, _CanvasDragState.zero, t),
        backdropFactor: ui.lerpDouble(startFactor, 1.0, t)!,
      );
    };
    _returnStatusListener = (status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        route._setCanvasDrag(_CanvasDragState.zero, backdropFactor: 1.0);
        _complete();
      }
    };
    returnController
      ..duration = returnDuration
      ..value = 0.0
      ..addListener(_returnTickListener!)
      ..addStatusListener(_returnStatusListener!)
      ..forward();
  }

  void cancelOnDispose() {
    if (_finished) return;
    _finished = true;
    _detachListeners();
    if (returnController.isAnimating) {
      returnController.stop();
    }
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
    _detachListeners();
    onFinished();
    if (navigator.mounted) {
      navigator.didStopUserGesture();
    }
  }

  void _detachListeners() {
    if (_routeStatusListener case final listener?) {
      _routeStatusListener = null;
      controller.removeStatusListener(listener);
    }
    if (_returnTickListener case final listener?) {
      _returnTickListener = null;
      returnController.removeListener(listener);
    }
    if (_returnStatusListener case final listener?) {
      _returnStatusListener = null;
      returnController.removeStatusListener(listener);
    }
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
