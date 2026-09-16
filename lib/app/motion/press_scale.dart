import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// M3-style press feedback: the child scales to [MotionTokens.pressScale]
/// while a pointer is down and releases back over [MotionTokens.press].
/// Passive wrapper — no gestures are consumed, so it composes over the
/// child's own InkWell/GestureDetector. Under reduced motion the scale
/// snaps via a zero duration rather than animating.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  var _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? MotionTokens.pressScale : 1,
        duration: MotionTokens.resolve(context, MotionTokens.press),
        curve: MotionTokens.pressCurve,
        child: widget.child,
      ),
    );
  }
}
