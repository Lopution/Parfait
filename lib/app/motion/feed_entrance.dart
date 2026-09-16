import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// First-screen feed entrance: item [index] fades in and rises
/// [MotionTokens.listEntranceOffset] over [MotionTokens.listEntrance],
/// delayed by `index * listStaggerStep`. Items at or beyond
/// [MotionTokens.listEntranceMaxItems] — i.e. everything scroll-built after
/// the first batch — render immediately; a mid-feed card popping in during a
/// fling reads as a layout bug, not motion.
///
/// The animation is an [Interval] window over a single
/// [TweenAnimationBuilder], so there is no controller or timer to leak and
/// the widget is cheap enough to wrap every feed child unconditionally.
class StaggeredEntrance extends StatelessWidget {
  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!MotionTokens.enabled(context) ||
        index < 0 ||
        index >= MotionTokens.listEntranceMaxItems) {
      return child;
    }
    final delay = MotionTokens.listStaggerStep * index;
    final total = MotionTokens.listEntrance + delay;
    // The entrance occupies the tail fraction after the per-index delay.
    final interval = Interval(
      delay.inMicroseconds / total.inMicroseconds,
      1,
      curve: MotionTokens.listEntranceCurve,
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      builder: (context, value, child) {
        final eased = interval.transform(value);
        return Opacity(
          opacity: eased,
          child: Transform.translate(
            offset: Offset(0, MotionTokens.listEntranceOffset * (1 - eased)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
