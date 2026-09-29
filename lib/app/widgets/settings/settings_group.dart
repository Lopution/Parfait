import 'package:material_ui/material_ui.dart';

import '../../theme/func_semantic_tokens.dart';

/// Inset settings group: optional header, one rounded surfaceContainer body
/// holding the rows, optional footnote below. Rows are separated by their own
/// padding — no dividers inside a group; the group's bottom padding
/// (FuncSpacing.xl) separates groups.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    this.footer,
    required this.children,
  });

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
          if (children.isNotEmpty)
            Material(
              color: colorScheme.surfaceContainer,
              shape: const RoundedRectangleBorder(borderRadius: FuncShape.card),
              clipBehavior: Clip.antiAlias,
              child: Column(children: children),
            ),
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
