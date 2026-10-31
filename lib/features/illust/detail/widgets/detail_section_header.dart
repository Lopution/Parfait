import 'package:material_ui/material_ui.dart';

import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/edge_icon_buttons.dart';

/// A detail-page section's title, marked as a heading for screen readers,
/// with an optional trailing action: a text button ("See all") from
/// [actionLabel], or an icon button as [action]. Every section of the page
/// — inside the info block or below it — starts with one, so headings sit
/// at one distance from what is above and below them.
class DetailSectionHeader extends StatelessWidget {
  const DetailSectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
    this.action,
  }) : assert(actionLabel == null || action == null);

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final actionLabel = this.actionLabel;
    return Padding(
      // The action's label or glyph, not its target, ends on the margin
      // (LAYOUT-15): a text button and an icon button both pad 12dp.
      padding: const EdgeInsetsDirectional.fromSTEB(
        FuncSpacing.lg,
        FuncSpacing.lg,
        FuncSpacing.lg - EdgeIconButtons.glyphInset,
        FuncSpacing.xs,
      ),
      child: ConstrainedBox(
        // The row keeps the action's height with or without one, so a
        // section never shifts when its action appears.
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                // A step below the work's title, in secondary ink, so
                // the title leads the page.
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            if (actionLabel != null)
              TextButton(
                // Narrower than the default 64dp: a short label would
                // centre away from the margin.
                style: TextButton.styleFrom(
                  minimumSize: const Size(kMinInteractiveDimension, 40),
                ),
                onPressed: onAction,
                child: Text(actionLabel),
              ),
            ?action,
          ],
        ),
      ),
    );
  }
}
