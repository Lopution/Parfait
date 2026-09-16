import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// Pushed-route transition: slide in from the trailing edge.
///
/// A live in-page animation (loaders, image fades, scroll ballistic,
/// playing GIFs) marks its enclosing repaint boundary dirty every frame, so
/// a route transition turns into a repaint storm instead of pure layer
/// compositing. [TickerMode] freezes tickers on both sides for the
/// transition window — the outgoing route animates, the incoming one drives
/// secondaryAnimation — and lets them resume afterwards. The pop snapshot
/// keeps the outgoing page a single blitted texture while it slides away.
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
    final curved = CurvedAnimation(
      parent: animation,
      curve: MotionTokens.pageCurve,
    );
    final inTransition =
        animation.isAnimating || secondaryAnimation.isAnimating;
    return TickerMode(
      enabled: !inTransition,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: RoutePopSnapshot(
          animation: animation,
          secondaryAnimation: secondaryAnimation,
          child: child,
        ),
      ),
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
    final curved = CurvedAnimation(
      parent: animation,
      curve: MotionTokens.modalCurve,
    );
    final inTransition =
        animation.isAnimating || secondaryAnimation.isAnimating;
    return TickerMode(
      enabled: !inTransition,
      child: FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: MotionTokens.modalSlideBegin,
            end: Offset.zero,
          ).animate(curved),
          child: RoutePopSnapshot(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Shell branch switch (bottom nav / NavigationRail): the incoming branch
/// fades in over [MotionTokens.branchFade]. The outgoing branch is an
/// IndexedStack child and cannot crossfade — it swaps atomically underneath,
/// so this is a fade-in, matching the "tab changes fade" vocabulary.
class FuncBranchFade extends StatefulWidget {
  const FuncBranchFade({super.key, required this.index, required this.child});

  /// The currently visible branch index; a change replays the fade.
  final int index;
  final Widget child;

  @override
  State<FuncBranchFade> createState() => _FuncBranchFadeState();
}

class _FuncBranchFadeState extends State<FuncBranchFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: MotionTokens.branchFade,
      value: 1,
    );
  }

  @override
  void didUpdateWidget(covariant FuncBranchFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _controller.duration = MotionTokens.resolve(
        context,
        MotionTokens.branchFade,
      );
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: _controller,
        curve: MotionTokens.branchFadeCurve,
      ),
      child: widget.child,
    );
  }
}

/// Freezes a page into a single texture while a route transition slides.
///
/// Impeller re-executes a route's whole display list on every frame of the
/// slide — both the outgoing page AND the one being revealed underneath.
/// On a device whose GPU/display pipeline has idled down after a few still
/// seconds (the "leave the page 2-3s then return" repro), that per-frame
/// re-raster blows the budget uniformly — a constant low-FPS animation
/// rather than dropped frames. [SnapshotWidget] is the same mechanism the
/// Material zoom/fade-forwards transitions use: while either animation is
/// running, the page is captured once at paint time and the remaining
/// frames blit one texture. The live subtree stays mounted, so cancelled
/// pops (predictive-back back-outs) restore instantly.
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

  bool get _animating =>
      widget.animation.isAnimating || widget.secondaryAnimation.isAnimating;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_sync);
    widget.secondaryAnimation.addStatusListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_sync);
    widget.secondaryAnimation.removeStatusListener(_sync);
    _controller.dispose();
    super.dispose();
  }

  void _sync([AnimationStatus? _]) {
    if (!_animating) {
      _controller.allowSnapshotting = false;
      return;
    }
    if (_controller.allowSnapshotting) return;
    // Defer snapshotting by one frame: HeroController also starts flights
    // from a post-frame callback, so the source Hero still paints its child
    // on the very first transition frame. Capturing then would bake the
    // image into this page's frozen texture — the pop would show it sliding
    // with the page AND flying as the shuttle (double image). One live
    // frame lets the placeholder swap land first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _animating) {
        _controller.allowSnapshotting = true;
      }
    });
  }

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
