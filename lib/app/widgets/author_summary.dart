import 'package:material_ui/material_ui.dart';

import '../person_avatar.dart';
import '../theme/func_semantic_tokens.dart';

/// Shared author row: avatar slot + name (+ optional account/handle) wrapped
/// in a single [InkWell]. Pages report the navigation intent through
/// [onTap]; the widget owns the layout so every surface keeps the same
/// avatar spacing, ellipsis behaviour, and ink shape.
///
/// `compact` drops the account line and shrinks the row for inline contexts
/// (novel cards); the standard variant keeps the two-line 48px slot used by
/// detail and user-feed surfaces.
class AuthorSummary extends StatelessWidget {
  const AuthorSummary({
    super.key,
    required this.name,
    required this.imageUrl,
    this.account,
    this.onTap,
    this.avatarRadius = 24,
    this.avatarKey,
    this.padding = EdgeInsets.zero,
    this.compact = false,
  });

  final String name;
  final String? account;
  final String? imageUrl;
  final VoidCallback? onTap;
  final double avatarRadius;
  final Key? avatarKey;
  final EdgeInsetsGeometry padding;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    final avatar = SizedBox.square(
      key: avatarKey,
      dimension: avatarRadius * 2,
      child: PersonAvatar(imageUrl: imageUrl, radius: avatarRadius),
    );
    final Widget content;
    if (compact) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          avatar,
          const SizedBox(width: FuncSpacing.sm),
          Flexible(
            child: Text(
              name,
              style: tokens.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    } else {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          avatar,
          const SizedBox(width: FuncSpacing.lg + FuncSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: tokens.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (account != null)
                  Text(
                    account!,
                    style: tokens.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      );
    }
    if (onTap == null) {
      return Padding(padding: padding, child: content);
    }
    return InkWell(
      onTap: onTap,
      borderRadius: FuncShape.control,
      child: Padding(padding: padding, child: content),
    );
  }
}
