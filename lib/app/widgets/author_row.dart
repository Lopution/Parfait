import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../navigation/routes.dart';
import '../theme/func_semantic_tokens.dart';
import 'author_summary.dart';

/// The whole avatar + name row opens the author's profile: one target at
/// least 48dp tall, announced as a button. [AuthorSummary] owns the avatar
/// and name layout; this row owns the target, the navigation and the
/// semantics. [trailing] (a follow button) stays a separate target.
class AuthorRow extends StatelessWidget {
  const AuthorRow({
    super.key,
    required this.userId,
    required this.name,
    this.avatarUrl,
    this.trailing,
  });

  /// Minimum height of the tap target (Material's 48dp touch target).
  static const double minHeight = kMinInteractiveDimension;
  static const double _avatarRadius = 16;

  final int userId;
  final String name;
  final String? avatarUrl;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    void open() => openUser(context, userId);
    final trailing = this.trailing;
    return Row(
      children: [
        Expanded(
          child: Semantics(
            container: true,
            button: true,
            label: name,
            hint: context.l10n.openAuthorProfile,
            onTap: open,
            excludeSemantics: true,
            child: InkWell(
              onTap: open,
              borderRadius: FuncShape.control,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: minHeight),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: AuthorSummary(
                    name: name,
                    imageUrl: avatarUrl,
                    avatarRadius: _avatarRadius,
                    compact: true,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: FuncSpacing.sm),
          trailing,
        ],
      ],
    );
  }
}
