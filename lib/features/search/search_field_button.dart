import 'package:material_ui/material_ui.dart';

import '../../app/theme/func_semantic_tokens.dart';

/// Looks like a search field, acts as a button: the input page owns typing.
///
/// The search guide shows the hint; the result page shows the query, in
/// the place the input page's field sits, so the field reads as the same
/// one across the push.
class SearchFieldButton extends StatelessWidget {
  const SearchFieldButton({
    super.key,
    required this.text,
    required this.onTap,
    this.isHint = false,
    this.tapHint,
  });

  static const double height = 48;

  final String text;
  final VoidCallback onTap;

  /// [text] is a placeholder, drawn in the muted hint colour.
  final bool isHint;

  /// What a tap does, for screen readers; null reads the default.
  final String? tapHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      button: true,
      onTapHint: tapHint,
      child: Material(
        color: colors.surfaceContainerHigh,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: height),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
              child: Row(
                children: [
                  Icon(Icons.search, color: colors.onSurfaceVariant),
                  // Where SearchBar puts its text after a bare leading icon.
                  const SizedBox(width: FuncSpacing.lg),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: isHint ? colors.onSurfaceVariant : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
