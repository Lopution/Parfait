import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../navigation/routes.dart';
import '../theme/func_semantic_tokens.dart';
import 'author_summary.dart';

/// An inline byline: the avatar and name, then a chevron that says the row
/// opens the author's profile. The whole row is one target at least 48dp
/// tall, announced as a button. [AuthorSummary] owns the avatar and name
/// layout; this row owns the target, the navigation and the semantics. An
/// author that stands as its own block is a `PersonCard` instead.
class AuthorRow extends StatelessWidget {
  const AuthorRow({
    super.key,
    required this.userId,
    required this.name,
    this.avatarUrl,
  });

  /// Minimum height of the tap target (Material's 48dp touch target).
  static const double minHeight = kMinInteractiveDimension;

  /// The chevron, as tall as the name's line.
  static const double _chevronSize = 20;

  final int userId;
  final String name;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    void open() => openUser(context, userId);
    return Semantics(
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
          child: Row(
            children: [
              Flexible(
                child: AuthorSummary(
                  name: name,
                  imageUrl: avatarUrl,
                  avatarRadius: 16,
                  compact: true,
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: _chevronSize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
