import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';
import 'spring_pop.dart';

/// Swaps a state icon (selection check mark, watchlist icon, download
/// state): the new icon fades in over the outgoing one on the
/// [MotionSpring.effectsFast] spring while the icon pops past its size by
/// [popPeak] and back ([SpringPop]), the way the bookmark heart does.
/// [value] names the state — the swap runs when it changes, not whenever
/// the child widget is rebuilt. The first build and reduced motion show
/// the icon at once.
class StateIconSwitcher extends StatefulWidget {
  const StateIconSwitcher({
    super.key,
    required this.value,
    required this.child,
  });

  /// The pop's overshoot: a little under the bookmark heart's.
  static const popPeak = 0.2;

  final Object value;
  final Widget child;

  @override
  State<StateIconSwitcher> createState() => _StateIconSwitcherState();
}

class _StateIconSwitcherState extends State<StateIconSwitcher> {
  var _swaps = 0;

  @override
  void didUpdateWidget(StateIconSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) _swaps++;
  }

  @override
  Widget build(BuildContext context) {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.effectsFast,
    );
    return SpringPop(
      pops: _swaps,
      peak: StateIconSwitcher.popPeak,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: curve,
        child: KeyedSubtree(key: ValueKey(widget.value), child: widget.child),
      ),
    );
  }
}
