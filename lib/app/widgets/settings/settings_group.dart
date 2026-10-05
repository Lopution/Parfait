import 'package:material_ui/material_ui.dart';

import '../../theme/func_semantic_tokens.dart';

/// Inset settings group: optional header, the rows, optional footnote below.
///
/// M3 Expressive segmented list: every row is its own surfaceContainer
/// segment, [segmentGap] apart; the group's outer corners are large, the
/// inner ones extra-small. A row that is one composite control (a segmented
/// button) is one segment — the group never splits a child. The group's
/// bottom padding (FuncSpacing.xl) separates groups.
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
          for (final (index, child) in children.indexed) ...[
            if (index > 0) const SizedBox(height: segmentGap),
            Material(
              color: colorScheme.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: segmentRadius(index, children.length),
              ),
              // Ink stays inside its own segment.
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ],
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
}
