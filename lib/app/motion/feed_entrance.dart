import 'package:flutter/widgets.dart';

import '../../core/debug/frame_probe.dart';
import 'motion_tokens.dart';

/// Feed entrance: item fades in over [MotionTokens.listEntrance], delayed
/// by a bounded per-index stagger for the first-screen batch only. It does
/// not move: the card lands where it sits.
///
/// The trigger is *first viewport exposure*, not mount: the list's
/// `cacheExtent` mounts cards half a viewport below the fold, and a
/// mount-triggered entrance plays to empty air — by the time the user
/// scrolls there, `_done` is already set and the card "pops" in
/// static. Exposure triggering also retires the old
/// `index < listEntranceMaxItems` cut-off: every card animates on arrival.
///
/// Two guards keep motion honest:
/// - **fling gate** — a card that enters the viewport while the scrollable
///   is ballistic appears *static* immediately (marked done, no animation):
///   holding it at Opacity(0) for the rest of the fling left visible blank
///   holes in a fast-scrolled feed, and a pop-in on settle would animate
///   under the reader's eye. The slow-drag path still plays the entrance.
/// - **once semantics** — pass the owning feed's [played] id set and an
///   entity animates at most once per set lifetime. Identity is keyed by
///   [id], not position — a refresh that inserts at the head shifts every
///   index, and a positional set would either replay surviving cards or
///   silently drop the entrance. Feed grids drop keep-alives, so a card
///   scrolling out and back rebuilds — without the set it replays the
///   entrance, which reads as a reload flash.
///
/// Items mounted or interrupted while [TickerMode] is disabled (a route
/// transition owns the ticker budget then) render the end state and count
/// as played: a frozen half-entrance baked into the pop snapshot and
/// replayed after landing was the "cards suddenly load" bug.
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.id,
    required this.child,
    this.played,
  });

  /// Position in the list — drives the stagger delay only.
  final int index;

  /// Stable entity identity — drives the once-per-list [played] mark.
  final int id;
  final Widget child;

  /// Mutable id set owned by the enclosing list's State. Ids are per-list;
  /// each list keeps its own set.
  final Set<int>? played;

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin, TickerModeWatch {
  /// Scroll velocity above which a newly-exposed card does not animate —
  /// mid-fling pop-ins read as bugs. Fling velocities run in the thousands;
  /// a deliberate slow drag stays far below this.
  static const _flingGateVelocity = 1000.0;

  /// The stagger delay is capped so a card 200 items deep doesn't wait
  /// seconds after exposure — delay was designed for the first screen.
  static const _maxStaggeredIndex = 8;

  late final AnimationController _controller = AnimationController(vsync: this);
  var _done = false;

  /// Latched once [build] has returned the animation wrapper. Dropping the
  /// wrapper after the entrance finishes would change the subtree shape,
  /// and the next parent rebuild would re-inflate the whole card (its
  /// image state included) — on device every feed rebuild did that to
  /// every played card in layout.
  var _wrapped = false;
  ScrollableState? _scrollable;

  /// Scroll offset captured when the position listener attached. A card
  /// that has seen any scroll since then is scroll-exposed, not part of
  /// the first-screen batch.
  double _attachPixels = 0;

  /// Whether the per-index stagger delay applies to this entrance. Only
  /// the first-screen batch staggers: a card surfaced by continued
  /// scrolling plays the same fade with `delayUs = 0` — holding it
  /// at Opacity(0) for a wait sized for the opening screen reads as a
  /// hole in a feed already in motion.
  var _staggered = true;

  /// Self-measured scroll velocity — `ScrollPosition.activity` is a
  /// protected API, so px/s is derived from position-listener deltas.
  /// Unknown means "assume fast": a card that can't prove the scroll is
  /// calm does not animate.
  var _velocityPxPerSec = double.infinity;
  double _lastPixels = 0;
  int _lastSampleMicros = 0;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) _markDone();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncDuration();
    _evaluate();
  }

  /// Frozen mid-entrance or before exposure: land on the end state. A
  /// played card has nothing to react to, so the flip rebuilds no card.
  @override
  void didChangeTickerMode(bool enabled) {
    if (!enabled) _evaluate();
  }

  @override
  void didUpdateWidget(StaggeredEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only a different entity resets the entrance. A pure index change is a
    // move (refresh re-seated the slot): the played id keeps its end state
    // instead of replaying the animation in place.
    if (oldWidget.id == widget.id) return;
    _detachScrollable();
    _controller.stop();
    _probePlaying(false);
    _staggered = true;
    _syncDuration();
    _done = false;
    _evaluate();
  }

  @override
  void dispose() {
    _detachScrollable();
    _probePlaying(false);
    _controller.dispose();
    super.dispose();
  }

  /// Whether this entrance is counted as a live frame-probe scene.
  var _probed = false;

  void _probePlaying(bool playing) {
    if (playing == _probed) return;
    _probed = playing;
    if (playing) {
      FrameProbe.instance.enter('entrance');
    } else {
      FrameProbe.instance.exit('entrance');
    }
  }

  /// The per-index wait before the fade; part of the controller's span.
  var _delay = Duration.zero;

  void _syncDuration() {
    _delay = MotionTokens.resolve(
      context,
      MotionTokens.listStaggerStep * _staggerIndex,
    );
    _controller.duration =
        _delay + MotionTokens.resolve(context, MotionTokens.listEntrance);
  }

  int get _staggerIndex => !_staggered
      ? 0
      : (widget.index < 0 ? 0 : widget.index.clamp(0, _maxStaggeredIndex));

  /// First-screen batch = mounted inside an idle viewport with no scroll
  /// since attach — the static opening frame the stagger was choreographed
  /// for. Any scroll activity after attach (a moved pixel, or a scroll
  /// still running) makes the card scroll-exposed instead.
  bool get _firstScreenBatch {
    final position = _scrollable?.position;
    if (position == null) return true;
    return !position.isScrollingNotifier.value &&
        position.pixels == _attachPixels;
  }

  void _evaluate() {
    if (_done) return;
    final skip =
        !MotionTokens.enabled(context) ||
        !tickersEnabled ||
        widget.index < 0 ||
        (widget.played?.contains(widget.id) ?? false);
    if (skip) {
      _markDone();
      return;
    }
    // Layout may not exist yet at didChangeDependencies — decide on the
    // first frame whether this card is already visible.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryPlayOrWatch());
  }

  void _tryPlayOrWatch() {
    if (_done || !mounted) return;
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) {
      // Not inside a scrollable — nothing to wait for.
      _play();
      return;
    }
    if (_scrollable != scrollable) {
      _detachScrollable();
      _scrollable = scrollable;
      _attachPixels = scrollable.position.pixels;
      _lastPixels = _attachPixels;
      _lastSampleMicros = DateTime.now().microsecondsSinceEpoch;
      // Below the fold (cacheExtent) or mid-fling: wait for exposure. The
      // position listener catches every scroll frame; the scrolling
      // notifier catches the settle edge where pixels stop changing.
      scrollable.position.addListener(_onScroll);
      scrollable.position.isScrollingNotifier.addListener(_onScroll);
    }
    // Attach first, gate second: on a hit _play/_markDone detaches again.
    _gate();
  }

  void _onScroll() {
    if (_done || !mounted) return;
    final position = _scrollable?.position;
    if (position == null) return;
    final now = DateTime.now().microsecondsSinceEpoch;
    final dt = now - _lastSampleMicros;
    if (dt > 0) {
      _velocityPxPerSec =
          ((position.pixels - _lastPixels) /
                  (dt / Duration.microsecondsPerSecond))
              .abs();
    }
    _lastPixels = position.pixels;
    _lastSampleMicros = now;
    _gate();
  }

  /// Decides a mounted card's reveal once it overlaps the viewport:
  /// calm/idle scroll plays the entrance; a fast scroll marks it done
  /// instantly so fling-exposed cards are never transparent gaps.
  void _gate() {
    if (_done || !mounted || !_isInViewport()) return;
    final position = _scrollable?.position;
    final midFling =
        position != null &&
        position.isScrollingNotifier.value &&
        _velocityPxPerSec >= _flingGateVelocity;
    if (midFling) {
      _markDone();
      return;
    }
    _play();
  }

  bool _isInViewport() {
    final box = context.findRenderObject();
    final viewport = _scrollable?.context.findRenderObject();
    if (box is! RenderBox || viewport is! RenderBox) return true;
    if (!box.hasSize || !viewport.hasSize) return true;
    final cardRect = box.localToGlobal(Offset.zero) & box.size;
    final viewportRect = viewport.localToGlobal(Offset.zero) & viewport.size;
    return cardRect.overlaps(viewportRect);
  }

  void _play() {
    // Decided at exposure, not at mount: first-screen batch keeps the
    // per-index wait; scroll-exposed cards start the same entrance
    // immediately. Duration and the build-time delay both derive from
    // _staggerIndex, so they are synced together here.
    _staggered = _firstScreenBatch;
    _syncDuration();
    _detachScrollable();
    _probePlaying(true);
    _controller.forward();
  }

  void _detachScrollable() {
    final scrollable = _scrollable;
    if (scrollable == null) return;
    _scrollable = null;
    scrollable.position.removeListener(_onScroll);
    scrollable.position.isScrollingNotifier.removeListener(_onScroll);
  }

  void _markDone() {
    _detachScrollable();
    _probePlaying(false);
    _done = true;
    widget.played?.add(widget.id);
    if (_controller.value != 1) _controller.value = 1;
  }

  @override
  Widget build(BuildContext context) {
    // Played before the first build (reduced motion, frozen tickers, an id
    // already in [played]): the card never needs the wrapper.
    if (_done && !_wrapped) return widget.child;
    _wrapped = true;
    final total = _controller.duration!.inMicroseconds;
    final delayUs = _delay.inMicroseconds;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        // The entrance occupies the tail fraction after the per-index delay.
        // A closed motion gate resolves both spans to zero: land on the
        // end state.
        final span = total - delayUs;
        final window = span <= 0
            ? 1.0
            : ((_controller.value * total - delayUs) / span).clamp(0.0, 1.0);
        return Opacity(
          opacity: MotionTokens.listEntranceCurve.transform(window),
          // The card joins the semantics tree when it mounts, with its
          // batch. Leaving the 0→visible flip to drop it in would send one
          // tree update per stagger step, and on Android every update makes
          // an accessibility service re-read the whole tree on the UI
          // thread.
          alwaysIncludeSemantics: true,
          child: child,
        );
      },
    );
  }
}
