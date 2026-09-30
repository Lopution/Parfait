import 'package:material_ui/material_ui.dart';

import 'pixiv_image.dart';
import 'theme/func_semantic_tokens.dart';

/// Shared profile avatar: soft neutral placeholder (never the blue
/// CircleAvatar fallback), explicit crossfade on load, and an optional white
/// ring so avatars stay readable over artwork backgrounds.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.imageUrl,
    this.radius = 26,
    this.ring = false,
  });

  final String? imageUrl;
  final double radius;
  final bool ring;

  /// Neutral placeholder used both while loading and when the user has no
  /// avatar: a light gradient disc with a low-contrast person glyph.
  Widget neutral(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.surfaceContainer),
      child: Center(
        child: Icon(
          Icons.person_outline,
          size: radius,
          color: colors.onSurfaceVariant.withValues(alpha: 0.55),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(shape: BoxShape.circle, color: colors.surface),
      padding: ring ? const EdgeInsets.all(FuncSpacing.xxs) : EdgeInsets.zero,
      child: ClipOval(
        child: imageUrl == null
            ? neutral(context)
            : SizedBox(
                width: radius * 2,
                height: radius * 2,
                child: PixivImage.avatar(
                  imageUrl!,
                  size: radius * 2,
                  placeholderWidget: neutral(context),
                ),
              ),
      ),
    );
  }
}
