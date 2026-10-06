import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/debug/frame_probe.dart';
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
    _probeSweep(false);
    _controller?.dispose();
    super.dispose();
  }

  /// Whether this skeleton is counted as a live frame-probe scene.
  var _probed = false;

  void _probeSweep(bool sweeping) {
    if (sweeping == _probed) return;
    _probed = sweeping;
    if (sweeping) {
      FrameProbe.instance.enter('skeleton');
    } else {
      FrameProbe.instance.exit('skeleton');
    }
  }

  /// One gate for the whole tree: when motion is off the controller never
  /// repeats and the bones get no sweep — they paint as flat
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
    _probeSweep(enabled);
  }

  @override
  Widget build(BuildContext context) {
    if (_nested) return widget.child;
    final colorScheme = Theme.of(context).colorScheme;
    final controller = _controller;
    return Semantics(
      label: widget.label,
      container: true,
      child: _SkeletonTone(
        color: colorScheme.surfaceContainer,
        highlight: colorScheme.surfaceContainerLow,
        sweep: MotionTokens.enabled(context) ? controller : null,
        // Each bone paints its slice of one tree-wide gradient, so the
        // sweep needs no ShaderMask: that was a full-page offscreen layer
        // on every frame the skeleton was up.
        child: _SkeletonRoot(child: ExcludeSemantics(child: widget.child)),
      ),
    );
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
          // Track the real text box: measure one line in the same style
          // and scaler so the bone keeps the font's true metrics, not an
          // assumed 1.2 line-height factor.
          final painter = TextPainter(
            text: TextSpan(text: ' ', style: effectiveStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          final measured = painter.height;
          painter.dispose();
          return measured;
        }();
    final tone = context.dependOnInheritedWidgetOfExactType<_SkeletonTone>();
    final color = tone?.color ?? Theme.of(context).colorScheme.surfaceContainer;
    return SizedBox(
      width: width,
      height: effectiveHeight,
      child: _BoneShape(
        color: color,
        highlight: tone?.highlight ?? color,
        sweep: tone?.sweep,
        borderRadius: _circle ? null : (borderRadius ?? FuncShape.control),
      ),
    );
  }
}

/// Publishes the bone colours and the shared sweep to [SkeletonBone]
/// descendants. A bone outside a [FuncSkeleton] falls back to the image
/// placeholder colour and stays static.
class _SkeletonTone extends InheritedWidget {
  const _SkeletonTone({
    required this.color,
    required this.highlight,
    required this.sweep,
    required super.child,
  });

  final Color color;
  final Color highlight;

  /// Shimmer progress, null when motion is off.
  final Animation<double>? sweep;

  @override
  bool updateShouldNotify(_SkeletonTone oldWidget) =>
      color != oldWidget.color ||
      highlight != oldWidget.highlight ||
      sweep != oldWidget.sweep;
}

/// The box the sweep gradient spans. A repaint boundary, so the bones'
/// per-frame repaint stops here.
class _SkeletonRoot extends SingleChildRenderObjectWidget {
  const _SkeletonRoot({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSkeletonRoot();
}

class _RenderSkeletonRoot extends RenderProxyBox {
  @override
  bool get isRepaintBoundary => true;
}

class _BoneShape extends LeafRenderObjectWidget {
  const _BoneShape({
    required this.color,
    required this.highlight,
    required this.sweep,
    required this.borderRadius,
  });

  final Color color;
  final Color highlight;
  final Animation<double>? sweep;

  /// Null paints a circle.
  final BorderRadius? borderRadius;

  @override
  _RenderBoneShape createRenderObject(BuildContext context) => _RenderBoneShape(
    color: color,
    highlight: highlight,
    sweep: sweep,
    borderRadius: borderRadius,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderBoneShape renderObject) {
    renderObject
      ..color = color
      ..highlight = highlight
      ..sweep = sweep
      ..borderRadius = borderRadius;
  }
}

/// Fills its box like an empty [Container]: the full extent where the
/// constraints are bounded, zero where they are not.
class _RenderBoneShape extends RenderBox {
  _RenderBoneShape({
    required Color color,
    required Color highlight,
    required Animation<double>? sweep,
    required BorderRadius? borderRadius,
  }) : _color = color,
       _highlight = highlight,
       _sweep = sweep,
       _borderRadius = borderRadius;

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  Color _highlight;
  set highlight(Color value) {
    if (value == _highlight) return;
    _highlight = value;
    markNeedsPaint();
  }

  Animation<double>? _sweep;
  set sweep(Animation<double>? value) {
    if (value == _sweep) return;
    if (attached) _sweep?.removeListener(markNeedsPaint);
    _sweep = value;
    if (attached) _sweep?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  BorderRadius? _borderRadius;
  set borderRadius(BorderRadius? value) {
    if (value == _borderRadius) return;
    _borderRadius = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _sweep?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _sweep?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(
    Size(
      constraints.hasBoundedWidth ? constraints.maxWidth : 0,
      constraints.hasBoundedHeight ? constraints.maxHeight : 0,
    ),
  );

  @override
  void paint(PaintingContext context, Offset offset) {
    final bounds = offset & size;
    final paint = Paint()..color = _color;
    final sweep = _sweep;
    final root = _root();
    if (sweep != null && root != null) {
      // A diagonal highlight band sweeps left→right across the whole
      // skeleton. The gradient's own axis travels with the controller:
      // outside the band the edge colours clamp to the plain bone colour.
      final slide = sweep.value * 3 - 1;
      final rootRect =
          (offset - localToGlobal(Offset.zero, ancestor: root)) & root.size;
      paint.shader = LinearGradient(
        begin: Alignment(slide - 1, -0.3),
        end: Alignment(slide, 0.3),
        colors: [_color, _highlight, _color],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(rootRect);
    }
    final radius = _borderRadius;
    if (radius == null) {
      context.canvas.drawOval(bounds, paint);
    } else {
      context.canvas.drawRRect(radius.toRRect(bounds), paint);
    }
  }

  _RenderSkeletonRoot? _root() {
    for (RenderObject? node = parent; node != null; node = node.parent) {
      if (node is _RenderSkeletonRoot) return node;
    }
    return null;
  }
}
