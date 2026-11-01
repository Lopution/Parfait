import 'package:material_ui/material_ui.dart';

import '../../../core/spotlight/spotlight_models.dart';
import '../../format/app_format.dart';
import '../../motion/press_scale.dart';
import '../../navigation/routes.dart';
import '../../pixiv_image.dart';
import '../../theme/func_semantic_tokens.dart';
import '../../theme/func_tokens.dart';
import 'illust_card.dart';

/// One pixivision article, shaped like a work card: a 16:9 image clipped
/// to the card radius, the title (two lines at most) and the publish date
/// under it on the page. The whole card opens the in-app article page.
class SpotlightArticleCard extends StatelessWidget {
  const SpotlightArticleCard({
    super.key,
    required this.article,
    required this.imageWidth,
  });

  static const double imageAspectRatio = 16 / 9;

  final SpotlightArticle article;

  /// The laid-out image width, so the thumbnail decodes for its slot.
  final double imageWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnailUrl = article.thumbnailUrl;
    final publishDate = article.publishDate;
    return PressScale(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          // The press is PressScale's alone: ink would spill onto the page
          // around the title (MOTION-06). Focus and hover keep the theme's.
          splashFactory: NoSplash.splashFactory,
          overlayColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.pressed)
                ? FuncTokens.transparent
                : null,
          ),
          borderRadius: FuncShape.card,
          onTap: () => openSpotlightArticle(
            context,
            articleId: article.id,
            articleUrl: article.articleUrl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: FuncShape.card,
                child: AspectRatio(
                  aspectRatio: imageAspectRatio,
                  child: thumbnailUrl == null
                      ? ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.newspaper_outlined,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        )
                      // App API thumbnails live on i.pximg.net, which refuses
                      // requests without the Pixiv referer.
                      : PixivImage.feed(thumbnailUrl, layoutWidth: imageWidth),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  IllustCard.textIndent,
                  FuncSpacing.xs,
                  IllustCard.textIndent,
                  FuncSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      article.title,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (publishDate != null) ...[
                      const SizedBox(height: FuncSpacing.xs),
                      Text(
                        AppFormat.date(context, publishDate),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
