import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/debug/frame_probe.dart';
import 'motion_tokens.dart';

/// Transition-window guard shared by every route transition: wraps the route
/// content in a [RoutePopSnapshot] through [transition], so the
/// platform-specific transform — slide, predictive-back shared element —
/// moves the captured texture when the route leaves the stage. Pages stay
/// live while they animate: tickers are never paused by the transition
/// itself (the Overlay still stops a fully covered route's tickers).
class FuncTransitionGuard extends StatelessWidget {
  const FuncTransitionGuard({
    super.key,
    required this.animation,
    required this.secondaryAnimation,
    required this.transition,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;

  /// The route's visual transition, applied around the snapshot.
  final Widget Function(Widget child) transition;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return transition(
      RoutePopSnapshot(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      ),
    );
  }
}

/// Pushed-route transition: slide in from the trailing edge.
class FuncRouteTransition extends StatelessWidget {
  const FuncRouteTransition({
    super.key,
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // drive(CurveTween) instead of CurvedAnimation: build methods run every
    // frame during the transition, and a CurvedAnimation is a stateful
    // listener-holding object — the curve evaluation is all that is needed.
    final curved = animation.drive(CurveTween(curve: MotionTokens.pageCurve));
    return FuncTransitionGuard(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      transition: (child) => SlideTransition(
        position: curved.drive(
          Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero),
        ),
        child: child,
      ),
      child: child,
    );
  }
}

/// Modal-page transition (search input and similar keyboard-first surfaces):
/// a short bottom-edge rise plus fade. No Hero flights originate here, so
/// the slide is intentionally subtler than the push transition.
class FuncModalTransition extends StatelessWidget {
  const FuncModalTransition({
    super.key,
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = animation.drive(CurveTween(curve: MotionTokens.modalCurve));
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: curved.drive(
          Tween<Offset>(begin: MotionTokens.modalSlideBegin, end: Offset.zero),
        ),
        child: RoutePopSnapshot(
          animation: animation,
          secondaryAnimation: secondaryAnimation,
          child: child,
        ),
      ),
    );
  }
}

/// Keeps a page real-time through a route transition and freezes into a
/// single texture only while it leaves the stage.
///
/// The official zoom transition also snapshots by role: with
/// `allowEnterRouteSnapshotting: false` its entering roles (the pushed and
/// the revealed page) stay live and its exiting roles (the popped and the
/// covered page) become textures. This widget keeps the pushed page live
/// the same way but swaps the two secondary roles — the press that opened
/// the route is still fading on the covered page, and a texture captured
/// at reveal time shows the page as it is now:
///
/// - entering (own [animation] forward): always live — icons, bookmark
///   state and image fades keep updating during the push;
/// - exiting (own [animation] reverse): one texture — the raster-heavy
///   direction, kept snapshotted like the official transitions;
/// - covered ([secondaryAnimation] forward): live, so press feedback
///   finishes visibly instead of baking into a texture; once the covering
///   opaque route completes, the Overlay stops its tickers anyway;
/// - revealed ([secondaryAnimation] reverse): a freshly captured texture —
///   `clear()` + re-capture at reveal start, so the replayed frame shows
///   the current state after the press highlight has faded.
///
/// A reveal that starts while the press feedback that opened the route
/// could still be fading (a back gesture interrupting the push, inside
/// [_pressSettleDuration] of the cover start) keeps the page live for that
/// whole reveal rather than freezing a half-faded highlight into the
/// texture. The live subtree stays mounted throughout, so cancelled pops
/// (predictive-back back-outs) restore instantly.
class RoutePopSnapshot extends StatefulWidget {
  const RoutePopSnapshot({
    super.key,
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  /// This route's own transition — animates while it enters or pops.
  final Animation<double> animation;

  /// The animation of the route stacked above — animates while that route
  /// covers or reveals this page.
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<RoutePopSnapshot> createState() => _RoutePopSnapshotState();
}

class _RoutePopSnapshotState extends State<RoutePopSnapshot> {
  final _controller = SnapshotController();

  /// How long after a cover starts a press highlight on this page could
  /// still be fading. Covers the PressScale spring-back (~225ms), the
  /// ink-highlight fade (200ms) and the ink-ripple fade-out (375ms) with
  /// headroom.
  static const _pressSettleDuration = Duration(milliseconds: 400);

  /// Frame-probe bookkeeping: whether this page's transition and capture
  /// are counted as live scenes.
  bool _probedTransition = false;
  bool _probedSnapshot = false;
  String _routeLabel = '';

  /// Whether this page is being covered by a route pushing on top of it.
  /// Starting a cover re-opens the press window: the pointer-up that
  /// triggered the push happened at most a frame before it.
  bool _covering = false;

  /// Whether the press feedback around the last cover start has had
  /// [_pressSettleDuration] to finish. True until the first cover begins;
  /// the wall-clock timer keeps running while the covered page's own
  /// tickers are frozen by the Overlay, so a later reveal always sees it
  /// settled.
  bool _pressSettled = true;
  Timer? _pressSettleTimer;
  bool _captureScheduled = false;

  bool get _animating =>
      widget.animation.isAnimating || widget.secondaryAnimation.isAnimating;

  /// Whether this page should be a texture right now. Only pages leaving
  /// the stage are ever frozen: the route popping out, and a covered route
  /// coming back into view once its press feedback has settled.
  bool get _wantsSnapshot {
    if (widget.animation.isAnimating &&
        widget.animation.status == AnimationStatus.reverse) {
      return true;
    }
    return widget.secondaryAnimation.isAnimating &&
        widget.secondaryAnimation.status == AnimationStatus.reverse &&
        _pressSettled;
  }

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_sync);
    widget.secondaryAnimation.addStatusListener(_sync);
  }

  @override
  void didUpdateWidget(RoutePopSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.animation, widget.animation)) {
      oldWidget.animation.removeStatusListener(_sync);
      widget.animation.addStatusListener(_sync);
    }
    if (!identical(oldWidget.secondaryAnimation, widget.secondaryAnimation)) {
      oldWidget.secondaryAnimation.removeStatusListener(_sync);
      widget.secondaryAnimation.addStatusListener(_sync);
    }
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (FrameProbe.available) {
      _routeLabel = _labelOf(ModalRoute.settingsOf(context));
    }
    // Here rather than in initState so the probe marks can name the route.
    _sync();
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_sync);
    widget.secondaryAnimation.removeStatusListener(_sync);
    _pressSettleTimer?.cancel();
    _probeTransition(false);
    _probeSnapshot(false);
    _controller.dispose();
    super.dispose();
  }

  void _updatePressWindow() {
    final covering =
        widget.secondaryAnimation.isAnimating &&
        widget.secondaryAnimation.status == AnimationStatus.forward;
    if (covering == _covering) return;
    _covering = covering;
    if (!covering) return;
    _pressSettled = false;
    _pressSettleTimer?.cancel();
    _pressSettleTimer = Timer(_pressSettleDuration, () {
      _pressSettleTimer = null;
      _pressSettled = true;
    });
  }

  void _sync([AnimationStatus? _]) {
    _probeTransition(_animating);
    _updatePressWindow();
    if (!_wantsSnapshot) {
      _captureScheduled = false;
      _controller.allowSnapshotting = false;
      _probeSnapshot(false);
      return;
    }
    if (_controller.allowSnapshotting || _captureScheduled) return;
    // Defer snapshotting by one frame: HeroController also starts flights
    // from a post-frame callback, so the source Hero still paints its child
    // on the very first transition frame. Capturing then would bake the
    // image into this page's frozen texture — the pop would show it sliding
    // with the page AND flying as the shuttle (double image). One live
    // frame lets the placeholder swap land first.
    _captureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _captureScheduled = false;
      if (mounted && _wantsSnapshot) {
        // Re-capture rather than replay: the texture a reveal shows is the
        // page's current state, including changes made while it was
        // covered and the press highlight after it finished fading.
        _controller
          ..clear()
          ..allowSnapshotting = true;
        _probeSnapshot(true);
      }
    });
  }

  void _probeTransition(bool active) {
    if (!FrameProbe.available || active == _probedTransition) return;
    _probedTransition = active;
    final probe = FrameProbe.instance;
    if (active) {
      probe
        ..enter('transition')
        ..mark('transition $_routeLabel ${_direction()}');
    } else {
      probe
        ..exit('transition')
        ..mark('transition $_routeLabel end');
    }
  }

  void _probeSnapshot(bool active) {
    if (!FrameProbe.available || active == _probedSnapshot) return;
    _probedSnapshot = active;
    if (active) {
      FrameProbe.instance
        ..enter('snapshot')
        ..mark('snapshot $_routeLabel');
    } else {
      FrameProbe.instance.exit('snapshot');
    }
  }

  /// Which way this page moves: its own animation enters/pops it, the
  /// secondary one covers/reveals it.
  String _direction() {
    if (widget.animation.isAnimating) {
      return widget.animation.status == AnimationStatus.forward ? 'in' : 'out';
    }
    return widget.secondaryAnimation.status == AnimationStatus.forward
        ? 'covered'
        : 'revealed';
  }

  static String _labelOf(RouteSettings? settings) => switch (settings) {
    RouteSettings(name: final name?) => name,
    Page(key: ValueKey(:final value)) => '$value',
    _ => '${settings?.runtimeType}',
  };

  @override
  Widget build(BuildContext context) {
    return SnapshotWidget(
      // permissive: a route containing a platform view/texture paints live
      // instead of throwing on an uncapturable subtree.
      mode: SnapshotMode.permissive,
      controller: _controller,
      child: RepaintBoundary(child: widget.child),
    );
  }
}
