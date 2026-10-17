import 'package:material_ui/material_ui.dart';

import 'motion_tokens.dart';
import 'spring_size.dart';

/// A block that comes and goes in place — a note, a banner, a status line:
/// as it appears the space opens on [SpringSize] while the block fades in;
/// as it goes it fades out, then the space closes. A null [child] is
/// hidden, and the last block stays drawn through its fade-out, taking no
/// taps and hidden from screen readers. The first build shows its state
/// at once; reduced motion and frozen tickers show and hide at once
/// (MOTION-02).
class Reveal extends StatefulWidget {
  const Reveal({super.key, this.child});

  final Widget? child;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  // Not lazy: a hidden first build never reads it, and created later it
  // would start at the shown value and skip the fade-in.
  late final AnimationController _opacity;

  /// What is drawn: the child, or the last one while it fades out.
  late Widget? _shown = widget.child;

  @override
  void initState() {
    super.initState();
    _opacity = AnimationController(
      vsync: this,
      value: widget.child == null ? 0 : 1,
    );
  }

  @override
  void didUpdateWidget(Reveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    final child = widget.child;
    if (child != null) {
      _shown = child;
      if (oldWidget.child == null) _fadeTo(1);
    } else if (oldWidget.child != null) {
      _fadeTo(0);
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    super.dispose();
  }

  void _fadeTo(double target) {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.effectsFast,
    );
    final ticking = TickerMode.getValuesNotifier(context).value.enabled;
    if (duration == Duration.zero || !ticking) {
      _opacity.value = target;
      if (target == 0) _shown = null;
      return;
    }
    _opacity
        .animateTo(target, duration: duration, curve: curve)
        .whenCompleteOrCancel(() {
          // A show that interrupted the fade-out keeps the block.
          if (!mounted || widget.child != null || _opacity.value > 0) return;
          setState(() => _shown = null);
        });
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final leaving = widget.child == null;
    return SpringSize(
      child: shown == null
          ? const SizedBox.shrink()
          // A block on its way out is already gone for touch and screen
          // readers: its callbacks belong to the state before the change.
          : IgnorePointer(
              ignoring: leaving,
              child: ExcludeSemantics(
                excluding: leaving,
                child: FadeTransition(
                  opacity: _opacity,
                  alwaysIncludeSemantics: true,
                  child: shown,
                ),
              ),
            ),
    );
  }
}
