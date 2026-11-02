import 'package:material_ui/material_ui.dart';

import '../theme/func_semantic_tokens.dart';

/// One fact of a work's metadata line (views, length, date, …): a small
/// glyph in the text's colour, then the text, in [MetaFact.style].
class MetaFact extends StatelessWidget {
  const MetaFact({
    super.key,
    required this.icon,
    required this.text,
    required this.style,
  });

  final IconData icon;
  final String text;
  final TextStyle style;

  /// Sized to the metadata text rather than the 24dp default.
  static const glyph = 14.0;

  /// The metadata text: small, in the secondary colour, with tabular
  /// figures so counts keep their width.
  static TextStyle styleOf(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.bodySmall!
        .copyWith(color: theme.colorScheme.onSurfaceVariant)
        .tabular;
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: glyph, color: style.color),
      const SizedBox(width: FuncSpacing.xs),
      // A long fact (a tools list, a series title) wraps inside itself.
      Flexible(child: Text(text, style: style)),
    ],
  );
}
