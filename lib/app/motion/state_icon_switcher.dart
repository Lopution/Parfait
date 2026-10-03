import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// Swaps a state icon (selection check mark, watchlist icon): the incoming
/// icon scales up from [enterScale] while fading in over the
/// [MotionSpring.effectsFast] spring, and the outgoing one fades away.
/// [value] names the state — the swap runs when it changes, not whenever
/// the child widget is rebuilt. The first build and reduced motion show
/// the icon at once.
class StateIconSwitcher extends StatelessWidget {
  const StateIconSwitcher({
    super.key,
    required this.value,
    required this.child,
  });

  /// Scale the incoming icon starts from.
  static const enterScale = 0.8;

  final Object value;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.effectsFast,
    );
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: curve,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: enterScale, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(value), child: child),
    );
  }
}
