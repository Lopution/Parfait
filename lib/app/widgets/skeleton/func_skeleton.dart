import 'package:material_ui/material_ui.dart';

import '../../motion/motion_tokens.dart';
import '../../theme/func_semantic_tokens.dart';

/// First-load placeholder (R3): paints [child]'s bones in the image
/// placeholder colour with one shared shimmer, and exposes a single
/// semantics node labelled [label]. Reduced motion keeps it static.
///
/// Nested inside another FuncSkeleton (a page skeleton embedding
/// `IllustGridSkeleton`) it renders [child] as-is: the outer one already
/// owns the tone, the shimmer and the semantics node, so the tree keeps
/// exactly one controller and one announcement.
class FuncSkeleton extends StatefulWidget {
  const FuncSkeleton({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  State<FuncSkeleton> createState() => _FuncSkeletonState();
}

class _FuncSkeletonState extends State<FuncSkeleton>
    with SingleTickerProviderStateMixin {
  /// Created on first use, so a nested skeleton never owns one.
  AnimationController? _controller;

  bool get _nested =>
      context.getInheritedWidgetOfExactType<_SkeletonTone>() != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_nested) _syncMotion();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// One gate for the whole tree: when motion is off the controller never
  /// repeats and no ShaderMask is built — the bones paint as flat
  /// placeholder colour.
  void _syncMotion() {
    final enabled = MotionTokens.enabled(context);
    final controller = _controller;
    if (enabled) {
      if (controller == null) {
        _controller = AnimationController(
          vsync: this,
          duration: MotionTokens.shimmer,
        )..repeat();
      } else if (!controller.isAnimating) {
        controller.repeat();
      }
    } else if (controller != null && controller.isAnimating) {
      controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_nested) return widget.child;
    final colorScheme = Theme.of(context).colorScheme;
    Widget body = _SkeletonTone(
      color: colorScheme.surfaceContainer,
      child: ExcludeSemantics(child: widget.child),
    );
    final controller = _controller;
    if (MotionTokens.enabled(context) && controller != null) {
      body = AnimatedBuilder(
        animation: controller,
        child: body,
        builder: (context, child) {
          // A diagonal highlight band sweeps left→right. The gradient's
          // own axis travels with the controller: outside the band the
          // edge colours clamp to the plain bone colour.
          final slide = controller.value * 3 - 1;
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment(slide - 1, -0.3),
              end: Alignment(slide, 0.3),
              colors: [
                colorScheme.surfaceContainer,
                colorScheme.surfaceContainerLow,
                colorScheme.surfaceContainer,
              ],
              stops: const [0.0, 0.5, 1.0],
            ).createShader(rect),
            child: child,
          );
        },
      );
    }
    return Semantics(label: widget.label, container: true, child: body);
  }
}

/// One placeholder shape. The colour comes from [FuncSkeleton], so bones
/// never hard-code a colour.
class SkeletonBone extends StatelessWidget {
  const SkeletonBone({
    super.key,
    this.width,
    this.height,
    this.borderRadius = FuncShape.control,
  }) : style = null,
       _circle = false;

  const SkeletonBone.circle({super.key, required double diameter})
    : width = diameter,
      height = diameter,
      borderRadius = null,
      style = null,
      _circle = true;

  /// A text-line bone: [height] follows the style's font size × line
  /// height so the placeholder matches the real text's box.
  const SkeletonBone.text({super.key, this.width, this.style})
    : height = null,
      borderRadius = null,
      _circle = false;

  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final TextStyle? style;
  final bool _circle;

  @override
  Widget build(BuildContext context) {
    final effectiveHeight =
        height ??
        () {
          final effectiveStyle = style ?? DefaultTextStyle.of(context).style;
          final fontSize = effectiveStyle.fontSize ?? 14;
          return fontSize * (effectiveStyle.height ?? 1.2);
        }();
    return Container(
      width: width,
      height: effectiveHeight,
      decoration: BoxDecoration(
        color: _SkeletonTone.of(context),
        shape: _circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: _circle ? null : (borderRadius ?? FuncShape.control),
      ),
    );
  }
}

/// Publishes the bone colour to [SkeletonBone] descendants. Falls back to
/// the image placeholder colour so a bone outside a [FuncSkeleton] still
/// renders honestly.
class _SkeletonTone extends InheritedWidget {
  const _SkeletonTone({required this.color, required super.child});

  final Color color;

  static Color of(BuildContext context) {
    final tone = context
        .dependOnInheritedWidgetOfExactType<_SkeletonTone>()
        ?.color;
    return tone ?? Theme.of(context).colorScheme.surfaceContainer;
  }

  @override
  bool updateShouldNotify(_SkeletonTone oldWidget) => color != oldWidget.color;
}
