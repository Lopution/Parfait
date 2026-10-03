import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// Fades a screen state in from 0 over the [MotionSpring.effectsFast]
/// spring when [kind] changes (skeleton → content, loading → error). The
/// old state is replaced, not cross-faded: two states never share a frame.
/// The first build shows its state at once, unless [fadeOnMount] — for
/// widgets that only ever appear as the result of a change (empty and
/// error states). Frozen tickers (a route transition) and reduced motion
/// show the state at once: a fade held at 0 under a frozen ticker would
/// leave the page blank for the whole transition.
class StateFade extends StatefulWidget {
  const StateFade({super.key, required this.kind, required this.child})
    : fadeOnMount = false;

  /// Fades in when first built; there is no kind to change.
  const StateFade.onMount({super.key, required this.child})
    : kind = null,
      fadeOnMount = true;

  final Object? kind;
  final bool fadeOnMount;
  final Widget child;

  @override
  State<StateFade> createState() => _StateFadeState();
}

class _StateFadeState extends State<StateFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _opacity = AnimationController(
    vsync: this,
    value: 1,
  );
  late bool _pendingMountFade = widget.fadeOnMount;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The spring needs the motion scope, so the mount fade starts here.
    if (_pendingMountFade) {
      _pendingMountFade = false;
      _fadeIn();
    }
  }

  @override
  void didUpdateWidget(StateFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) _fadeIn();
  }

  @override
  void dispose() {
    _opacity.dispose();
    super.dispose();
  }

  void _fadeIn() {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.effectsFast,
    );
    if (duration == Duration.zero || !TickerMode.valuesOf(context).enabled) {
      _opacity.value = 1;
      return;
    }
    _opacity
      ..value = 0
      ..animateTo(1, duration: duration, curve: curve);
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    // The state is already current: screen readers get it at once.
    alwaysIncludeSemantics: true,
    child: widget.child,
  );
}
