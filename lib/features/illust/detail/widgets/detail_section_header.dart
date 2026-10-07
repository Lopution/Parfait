import 'package:material_ui/material_ui.dart';

import '../../../../app/theme/func_semantic_tokens.dart';

/// A detail-page section's title, marked as a heading for screen readers,
/// with an optional trailing action ("See all"). Indented like the info
/// block above it.
class DetailSectionHeader extends StatelessWidget {
  const DetailSectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final actionLabel = this.actionLabel;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        FuncSpacing.xl,
        FuncSpacing.xl,
        FuncSpacing.md,
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
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            if (actionLabel != null)
              TextButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
