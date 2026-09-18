import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// First-screen feed entrance: item [index] fades in and rises
/// [MotionTokens.listEntranceOffset] over [MotionTokens.listEntrance],
/// delayed by `index * listStaggerStep`. Items at or beyond
/// [MotionTokens.listEntranceMaxItems] — i.e. everything scroll-built after
/// the first batch — render immediately; a mid-feed card popping in during
/// a fling reads as a layout bug, not motion.
///
/// Once semantics: pass the owning feed's [played] index set and an index
/// animates at most once per set lifetime. Feed grids drop keep-alives, so
/// a card scrolling out and back rebuilds — without the set it replays the
/// entrance, which reads as a reload flash. Items mounted or interrupted
/// while [TickerMode] is disabled (a route transition owns the ticker
/// budget then) render the end state and count as played: a frozen
/// half-entrance baked into the pop snapshot and replayed after landing
/// was the "cards suddenly load" bug.
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
    this.played,
  });

  final int index;
  final Widget child;

  /// Mutable index set owned by the enclosing list's State. Indices are
  /// per-list; each list keeps its own set.
  final Set<int>? played;

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  var _done = false;

  @override
  void initState() {
    super.initState();
    _syncDuration();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) _markDone();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _evaluate();
  }

  @override
  void didUpdateWidget(StaggeredEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    // Slot re-seated to a new index — re-evaluate against the played set.
    _controller.stop();
    _syncDuration();
    _done = false;
    _evaluate();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncDuration() {
    _controller.duration =
        MotionTokens.listEntrance + MotionTokens.listStaggerStep * widget.index;
  }

  void _evaluate() {
    if (_done) return;
    final skip =
        !MotionTokens.enabled(context) ||
        !TickerMode.valuesOf(context).enabled ||
        widget.index < 0 ||
        widget.index >= MotionTokens.listEntranceMaxItems ||
        (widget.played?.contains(widget.index) ?? false);
    if (skip) {
      _markDone();
    } else {
      _controller.forward();
    }
  }

  void _markDone() {
    _done = true;
    widget.played?.add(widget.index);
    if (_controller.value != 1) _controller.value = 1;
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    final total = _controller.duration!.inMicroseconds;
    final delayUs =
        (MotionTokens.listStaggerStep * widget.index).inMicroseconds;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        // The entrance occupies the tail fraction after the per-index delay.
        final window =
            ((_controller.value * total - delayUs) / (total - delayUs)).clamp(
              0.0,
              1.0,
            );
        final eased = MotionTokens.listEntranceCurve.transform(window);
        return Opacity(
          opacity: eased,
          child: Transform.translate(
            offset: Offset(0, MotionTokens.listEntranceOffset * (1 - eased)),
            child: child,
          ),
        );
      },
    );
  }
}
