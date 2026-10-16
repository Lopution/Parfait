import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// Initial velocity that carries an underdamped spring released at rest
/// position out to [peak]. For x(t) = v/ωd · e^(−ζωt) · sin(ωd t) the
/// first peak is v/ω · e^(−ζθ/√(1−ζ²)) with θ = atan(√(1−ζ²)/ζ).
double springKickVelocity(SpringDescription spring, double peak) {
  final omega = math.sqrt(spring.stiffness / spring.mass);
  final zeta = spring.damping / (2 * math.sqrt(spring.stiffness * spring.mass));
  final root = math.sqrt(1 - zeta * zeta);
  final theta = math.atan(root / zeta);
  return peak * omega * math.exp(zeta * theta / root);
}

/// Pops [child] past its size by [peak] and back each time [pops] grows:
/// a kick from rest on the [MotionSpring.expressiveSpatialFast] spring,
/// the bookmark heart's add pop. A state switch the user caused counts up
/// [pops]; a rebuild, a refresh or a first build does not. Reduced motion
/// shows no pop.
class SpringPop extends StatefulWidget {
  const SpringPop({
    super.key,
    required this.pops,
    required this.peak,
    required this.child,
  });

  final int pops;

  /// The overshoot above the rest scale of 1.
  final double peak;
  final Widget child;

  @override
  State<SpringPop> createState() => _SpringPopState();
}

class _SpringPopState extends State<SpringPop>
    with SingleTickerProviderStateMixin {
  /// Unbounded so the pop may pass 1.
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );

  @override
  void didUpdateWidget(SpringPop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pops > oldWidget.pops) _pop();
  }

  void _pop() {
    final spring = MotionTokens.spring(
      context,
      MotionSpring.expressiveSpatialFast,
    );
    if (spring == null) return;
    _scale.animateWith(
      SpringSimulation(
        spring,
        1,
        1,
        springKickVelocity(spring, widget.peak),
        snapToEnd: true,
      ),
    );
  }

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ScaleTransition(scale: _scale, child: widget.child);
}
