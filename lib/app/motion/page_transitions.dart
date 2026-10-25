import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/debug/frame_probe.dart';
import '../../core/platform/app_root_pipeline_owner.dart';

/// A route transition's curve that turns around where it is: over a whole
/// opening it is [curve] and over a whole leave [reverseCurve], but a leave
/// that cuts an opening short (or the other way round) runs the rest of
/// the way from the value it had reached, on the other direction's curve,
/// over what the route has left to run. `CurvedAnimation` keeps the curve
/// it started with, so a push cut short by back played the push curve
/// backwards: the slide, steep at its start, crept back and then left the
/// screen at full speed.
///
/// It follows [route]'s direction and maps only that animation's values;
/// it lives as long as [route].
class TurnCurve extends Curve {
  TurnCurve(this.route, {required this.curve, Curve? reverseCurve})
    : reverseCurve = reverseCurve ?? curve.flipped,
      _run = _Run(route.status) {
    route.addStatusListener(_onStatus);
  }

  /// [route] run through a new [TurnCurve].
  static Animation<double> drive(
    Animation<double> route, {
    required Curve curve,
    Curve? reverseCurve,
  }) => route.drive(
    CurveTween(
      curve: TurnCurve(route, curve: curve, reverseCurve: reverseCurve),
    ),
  );

  final Animation<double> route;
  final Curve curve;
  final Curve reverseCurve;

  /// Curves are immutable; the run this one is on changes with [route].
  final _Run _run;

  void _onStatus(AnimationStatus status) {
    final previous = _run.status;
    if (status.isAnimating && previous.isAnimating && status != previous) {
      final t = route.value;
      _run.turn(status, t, _valueOn(previous, t));
    } else {
      _run.start(status);
    }
  }

  double _valueOn(AnimationStatus direction, double t) {
    final _Run(:fromT, :fromValue) = _run;
    return switch (direction) {
      AnimationStatus.forward when fromT < 1 =>
        fromValue +
            (1 - fromValue) *
                curve.transform(((t - fromT) / (1 - fromT)).clamp(0.0, 1.0)),
      AnimationStatus.reverse when fromT > 0 =>
        fromValue * reverseCurve.transform((t / fromT).clamp(0.0, 1.0)),
      _ => t,
    };
  }

  @override
  double transformInternal(double t) => _valueOn(_run.status, t);
}

/// The way a [TurnCurve]'s route runs, and the route value and curve value
/// the run began at: an end, unless it turned another run around.
class _Run {
  _Run(this.status) {
    start(status);
  }

  AnimationStatus status;
  double fromT = 0;
  double fromValue = 0;

  void start(AnimationStatus status) {
    this.status = status;
    if (status.isAnimating) {
      fromT = fromValue = status == AnimationStatus.forward ? 0 : 1;
    }
  }

  void turn(AnimationStatus status, double t, double value) {
    this.status = status;
    fromT = t;
    fromValue = value;
  }
}

/// Transition-window guard shared by every route transition: wraps the route
/// content in a [RoutePopSnapshot] through [transition], so the transform
/// (the slide) moves the captured texture when the route leaves the stage. Pages stay
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
/// could still be fading (back interrupting the push, inside
/// [_pressSettleDuration] of the cover start) keeps the page live for that
/// whole reveal rather than freezing a half-faded highlight into the
/// texture. A finger put down on the revealed page turns it live for the
/// rest of the reveal, so a scroll or a press shows as it happens, not
/// when the reveal ends. The live subtree stays mounted throughout.
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
  /// ink-highlight fade (200ms) and Android's M3 ink sparkle, which runs
  /// 617ms from the tap: with 400ms, back pressed half a second after a
  /// tap froze the fading sparkle into the reveal's texture, and it went
  /// at once when the reveal ended.
  static const _pressSettleDuration = Duration(milliseconds: 650);

  /// Frame-probe bookkeeping: whether this page's transition and capture
  /// are counted as live scenes.
  bool _probedTransition = false;
  bool _probedSnapshot = false;

  /// Releases this page's semantics hold while it transitions.
  VoidCallback? _releaseSemantics;
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

  /// Whether a finger came down on this page during the current reveal.
  bool _touched = false;

  bool get _animating =>
      widget.animation.isAnimating || widget.secondaryAnimation.isAnimating;

  bool get _revealing =>
      widget.secondaryAnimation.isAnimating &&
      widget.secondaryAnimation.status == AnimationStatus.reverse;

  /// Whether this page should be a texture right now. Only pages leaving
  /// the stage are ever frozen: the route popping out, and a covered route
  /// coming back into view once its press feedback has settled, until a
  /// finger touches it.
  bool get _wantsSnapshot {
    if (widget.animation.isAnimating &&
        widget.animation.status == AnimationStatus.reverse) {
      return true;
    }
    return _revealing && _pressSettled && !_touched;
  }

  void _onPointerDown(PointerDownEvent _) {
    if (!_revealing || _touched) return;
    _touched = true;
    _sync();
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
    _holdSemantics(false);
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
    _holdSemantics(_animating);
    _updatePressWindow();
    if (!_revealing) _touched = false;
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

  void _holdSemantics(bool active) {
    if (active == (_releaseSemantics != null)) return;
    if (active) {
      _releaseSemantics = AppRootPipelineOwner.holdSemantics();
    } else {
      _releaseSemantics!();
      _releaseSemantics = null;
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
    return Listener(
      onPointerDown: _onPointerDown,
      child: SnapshotWidget(
        // permissive: a route containing a platform view/texture paints
        // live instead of throwing on an uncapturable subtree.
        mode: SnapshotMode.permissive,
        controller: _controller,
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}
