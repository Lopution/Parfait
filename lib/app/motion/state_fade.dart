import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// Fades a screen state in over the [MotionSpring.effectsFast] spring when
/// [kind] changes (skeleton → content, loading → error). The old state is
/// replaced, not cross-faded: two states never share a frame.
/// The first build shows its state at once, unless [fadeOnMount] — for
/// widgets that only ever appear as the result of a change (empty and
/// error states). Frozen tickers (a route transition) and reduced motion
/// show the state at once: a fade held at 0 under a frozen ticker would
/// leave the page blank for the whole transition.
class StateFade extends StatefulWidget {
  const StateFade({super.key, required this.kind, required this.child})
    : fadeOnMount = false,
      _sliver = false;

  /// Fades in when first built; there is no kind to change.
  const StateFade.onMount({super.key, required this.child})
    : kind = null,
      fadeOnMount = true,
      _sliver = false;

  /// [StateFade] for a sliver [child] — a section of a scroll view.
  const StateFade.sliver({
    super.key,
    required this.kind,
    required Widget sliver,
  }) : child = sliver,
       fadeOnMount = false,
       _sliver = true;

  final Object? kind;
  final bool fadeOnMount;
  final Widget child;
  final bool _sliver;

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

  /// The lowest opacity that still paints: alpha is rounded to 1/255
  /// steps and a 0 alpha skips the child.
  static const _firstPaint = 1 / 255;

  /// Paints the new state once at [_firstPaint] in the frame it enters the
  /// tree, then fades from there after that frame. Started inside the
  /// frame, the fade's clock would run from that frame's start, and a long
  /// first frame (building the content) would jump the fade halfway into a
  /// first paint.
  void _fadeIn() {
    if (_fadeCurve() == null) {
      _opacity.value = 1;
      return;
    }
    _opacity.value = _firstPaint;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Reduced motion or a transition may have begun since.
      final fade = _fadeCurve();
      if (fade == null) {
        _opacity.value = 1;
        return;
      }
      final (duration, curve) = fade;
      _opacity.animateTo(1, duration: duration, curve: curve);
    });
  }

  /// The fade's duration and curve, or null when the state shows at once.
  (Duration, Curve)? _fadeCurve() {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.effectsFast,
    );
    // Read, not depended on: a dependency would rebuild this on every
    // transition's ticker flip for nothing.
    final tickersEnabled = TickerMode.getValuesNotifier(context).value.enabled;
    if (duration == Duration.zero || !tickersEnabled) return null;
    return (duration, curve);
  }

  // The state is already current: screen readers get it at once.
  @override
  Widget build(BuildContext context) => widget._sliver
      ? SliverFadeTransition(
          opacity: _opacity,
          alwaysIncludeSemantics: true,
          sliver: widget.child,
        )
      : FadeTransition(
          opacity: _opacity,
          alwaysIncludeSemantics: true,
          child: widget.child,
        );
}
