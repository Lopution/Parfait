import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../motion/motion_tokens.dart';
import '../../motion/removal.dart';
import '../../theme/func_semantic_tokens.dart';

/// Inset settings group: optional header, the rows, optional footnote below.
///
/// M3 Expressive segmented list: every row is its own surfaceContainer
/// segment, [segmentGap] apart; the group's outer corners are large, the
/// inner ones extra-small. A row that is one composite control (a segmented
/// button) is one segment — the group never splits a child. The group's
/// bottom padding (FuncSpacing.xl) separates groups.
///
/// Under a [RemovalScope], a [Removable] row whose exit is playing no
/// longer counts: the other segments take their final corners and gaps as
/// the exit starts, animated on the same spring as the row's collapse, so
/// nothing jumps when the data drops the row.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    this.footer,
    required this.children,
  });

  /// Space between two segments of one group.
  static const double segmentGap = 2;

  /// Corners of the segment at [index] in a group of [count]: the group's
  /// outer edge uses the card radius, edges facing another segment
  /// [FuncShape.segment].
  static BorderRadius segmentRadius(int index, int count) {
    final outer = FuncShape.card.topLeft;
    final inner = FuncShape.segment.topLeft;
    final top = index == 0 ? outer : inner;
    final bottom = index == count - 1 ? outer : inner;
    return BorderRadius.vertical(top: top, bottom: bottom);
  }

  /// Section heading, rendered as a semantics header in onSurfaceVariant.
  /// A whole row (title + action button) is allowed — only its text picks up
  /// the heading style.
  final Widget? title;

  /// Explanatory text below the rows ("先看行，再看说明").
  final Widget? footer;

  /// The group's rows. An empty list skips the container — title and footer
  /// still render (an empty mute section reads as its heading only).
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final title = this.title;
    final footer = this.footer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        0,
        FuncSpacing.lg,
        FuncSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FuncSpacing.lg,
                0,
                FuncSpacing.lg,
                FuncSpacing.sm,
              ),
              child: DefaultTextStyle.merge(
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
                child: Semantics(header: true, child: title),
              ),
            ),
          if (children.isNotEmpty) _segments(context),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FuncSpacing.lg,
                FuncSpacing.sm,
                FuncSpacing.lg,
                0,
              ),
              child: DefaultTextStyle.merge(
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                child: footer,
              ),
            ),
        ],
      ),
    );
  }

  Widget _segments(BuildContext context) {
    final leaving = RemovalScope.maybeOf(context)?.leaving;
    if (leaving == null) return _layoutSegments(context, const {});
    return ValueListenableBuilder(
      valueListenable: leaving,
      builder: (context, ids, _) => _layoutSegments(context, ids),
    );
  }

  Widget _layoutSegments(BuildContext context, Set<Object> leaving) {
    bool isLeaving(Widget child) =>
        child is Removable && leaving.contains(child.id);
    final present = children.where((child) => !isLeaving(child)).length;
    final motion = MotionTokens.springCurve(context, MotionSpring.spatialFast);
    final segments = <Widget>[];
    var position = 0;
    for (final (index, child) in children.indexed) {
      final key = child is Removable ? ValueKey(child.id) : null;
      if (isLeaving(child)) {
        // Keeps its corners while it collapses; its gap closes with it.
        segments.add(
          _Segment(
            key: key,
            gap: 0,
            radius: segmentRadius(index, children.length),
            motion: motion,
            child: child,
          ),
        );
        continue;
      }
      segments.add(
        _Segment(
          key: key,
          gap: position > 0 ? segmentGap : 0,
          radius: segmentRadius(position, present),
          motion: motion,
          child: child,
        ),
      );
      position++;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: segments,
    );
  }
}

/// One row of a [SettingsGroup] and the gap above it. Gap and corners
/// animate on [motion] when the group reshapes.
class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.gap,
    required this.radius,
    required this.motion,
    required this.child,
  });

  final double gap;
  final BorderRadius radius;
  final (Duration, Curve) motion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final (duration, curve) = motion;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TweenAnimationBuilder(
          tween: Tween(end: gap),
          duration: duration,
          curve: curve,
          // The spring curve can land a hair past its end: below zero here.
          builder: (context, height, _) =>
              SizedBox(height: math.max(height, 0)),
        ),
        Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          shape: RoundedRectangleBorder(borderRadius: radius),
          // Material animates a shape change itself (with its own curve).
          animationDuration: duration,
          // Ink stays inside its own segment.
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      ],
    );
  }
}
