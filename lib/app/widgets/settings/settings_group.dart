import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../motion/motion_tokens.dart';
import '../../motion/removal.dart';
import '../../theme/func_semantic_tokens.dart';
import 'settings_anchor.dart';

/// Inset settings group: optional header, the rows, optional footnote below.
///
/// Every row is its own surfaceContainer card with [FuncShape.card] corners,
/// [rowGap] apart. A row that is one composite control (a slider block) is
/// one card — the group never splits a child. The group's bottom padding
/// (FuncSpacing.xl) separates groups.
///
/// Under a [RemovalScope], a [Removable] row whose exit is playing no
/// longer counts: the gap above it closes as the exit starts, animated on
/// the same spring as the row's collapse, so nothing jumps when the data
/// drops the row.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    this.footer,
    this.setting,
    required this.children,
  });

  /// The catalog entry this group is the place of (settings search): a
  /// choice group, or a block whose rows only exist in some states. When
  /// the search reveals it, every row takes the mark.
  final SettingsEntry? setting;

  /// Space between two rows of one group.
  static const double rowGap = FuncSpacing.sm;

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
    final setting = this.setting;
    final group = Padding(
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
          if (children.isNotEmpty) _rows(context),
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
    if (setting == null) return group;
    return SettingAnchor(entry: setting, paintsMark: false, child: group);
  }

  Widget _rows(BuildContext context) {
    final leaving = RemovalScope.maybeOf(context)?.leaving;
    if (leaving == null) return _layoutRows(context, const {});
    return ValueListenableBuilder(
      valueListenable: leaving,
      builder: (context, ids, _) => _layoutRows(context, ids),
    );
  }

  Widget _layoutRows(BuildContext context, Set<Object> leaving) {
    final motion = MotionTokens.springCurve(context, MotionSpring.spatialFast);
    final rows = <Widget>[];
    var position = 0;
    for (final child in children) {
      final key = child is Removable ? ValueKey(child.id) : null;
      // A leaving row's gap closes with it as it collapses.
      final isLeaving = child is Removable && leaving.contains(child.id);
      rows.add(
        _Row(
          key: key,
          gap: isLeaving || position == 0 ? 0 : rowGap,
          motion: motion,
          child: child,
        ),
      );
      if (!isLeaving) position++;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

/// One row of a [SettingsGroup] and the gap above it. The gap animates on
/// [motion] when the group reshapes.
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.gap,
    required this.motion,
    required this.child,
  });

  final double gap;
  final (Duration, Curve) motion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final (duration, curve) = motion;
    final mark = SettingHighlight.maybeOf(context);
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
          shape: const RoundedRectangleBorder(borderRadius: FuncShape.card),
          // Ink stays inside its own card.
          clipBehavior: Clip.antiAlias,
          child: mark == null
              ? child
              : SettingMarkOverlay(mark: mark, child: child),
        ),
      ],
    );
  }
}
