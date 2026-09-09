import 'package:flutter/material.dart';

import 'pixiv_image.dart';

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
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.surfaceContainerHighest,
            colors.surfaceContainerHigh,
          ],
        ),
      ),
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
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colors.surface,
      ),
      padding: EdgeInsets.all(ring ? 2 : 0),
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
