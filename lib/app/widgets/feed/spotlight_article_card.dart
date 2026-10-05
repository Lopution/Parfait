import 'package:material_ui/material_ui.dart';

import '../../../core/spotlight/spotlight_models.dart';
import '../../format/app_format.dart';
import '../../motion/press_scale.dart';
import '../../navigation/routes.dart';
import '../../pixiv_image.dart';
import '../../theme/func_semantic_tokens.dart';

/// One pixivision article: a 16:9 image, the title (two lines at most) and
/// the publish date under it. The whole card opens the in-app article page.
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
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openSpotlightArticle(
            context,
            articleId: article.id,
            articleUrl: article.articleUrl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
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
              Padding(
                padding: const EdgeInsets.all(FuncSpacing.md),
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
