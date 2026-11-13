import 'package:material_ui/material_ui.dart';

import '../../app/theme/func_semantic_tokens.dart';

/// A section title on search surfaces. With [onTap] the whole row is one
/// target (at least 48dp tall) ending in [action] and a chevron; a
/// [trailing] control instead sits at the row's end on its own.
class SearchSectionHeader extends StatelessWidget {
  const SearchSectionHeader({
    super.key,
    required this.title,
    this.action,
    this.onTap,
    this.trailing,
  }) : assert(trailing == null || onTap == null);

  final String title;
  final String? action;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final action = this.action;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                // Two lines: large text and long locales next to an action.
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (action != null) ...[
              Text(
                action,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              Icon(Icons.chevron_right, color: theme.colorScheme.primary),
            ],
            ?trailing,
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: FuncSpacing.sm),
      child: onTap == null
          ? Semantics(header: true, child: row)
          : MergeSemantics(
              child: Semantics(
                header: true,
                button: true,
                child: InkWell(onTap: onTap, child: row),
              ),
            ),
    );
  }
}
