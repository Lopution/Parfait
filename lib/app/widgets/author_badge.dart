import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../theme/func_semantic_tokens.dart';

/// "Author" beside a name in a work's comments: the work's creator is
/// talking. Brand-tinted like a tag, so it reads as a marker, not a button.
class AuthorBadge extends StatelessWidget {
  const AuthorBadge({super.key});

  /// Brand fill strength, the tag pill's.
  static const _fillAlpha = 0.14;

  /// Badge geometry rather than page spacing, so it stays off the
  /// [FuncSpacing] ladder.
  static const double _inset = 6;

  @override
  Widget build(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.brand.withValues(alpha: _fillAlpha),
        borderRadius: FuncShape.badge,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _inset,
          vertical: FuncSpacing.xxs,
        ),
        child: Text(
          context.l10n.commentAuthorBadge,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: tokens.brand,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
