import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// [AnimatedSize] on the [MotionSpring.spatialFast] spring: an expanding
/// or collapsing section changes height smoothly instead of jumping. Pair
/// newly shown content with `StateFade.onMount` so it fades in as the
/// space opens. Reduced motion resizes at once.
class SpringSize extends StatelessWidget {
  const SpringSize({
    super.key,
    required this.child,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.spatialFast,
    );
    // A zero-duration AnimatedSize re-dirties itself during its own layout.
    if (duration == Duration.zero) return child;
    return AnimatedSize(
      duration: duration,
      curve: curve,
      alignment: alignment,
      child: child,
    );
  }
}
