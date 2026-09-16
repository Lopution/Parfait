import 'package:material_ui/material_ui.dart';

import '../../core/novel/novel_entity.dart';
import '../../l10n/context.dart';
import '../motion/press_scale.dart';
import '../navigation/routes.dart';
import '../pixiv_image.dart';

/// Shared novel list row: cover, title, author, word count. Used by the
/// recommended novel feed and the novel ranking page.
class NovelRow extends StatelessWidget {
  const NovelRow({super.key, required this.entity});

  final NovelEntity entity;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: InkWell(
          onTap: () => openNovel(context, entity.id),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _NovelCover(entity: entity),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entity.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        entity.user.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${entity.textLength} ${context.l10n.novelWords}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NovelCover extends StatelessWidget {
  const _NovelCover({required this.entity});

  final NovelEntity entity;

  @override
  Widget build(BuildContext context) {
    final url = entity.coverImageUrl;
    if (url == null) {
      return Container(
        width: 56,
        height: 72,
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: const Icon(Icons.menu_book_outlined),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: 56,
        height: 72,
        child: PixivImage.feed(
          url,
          layoutWidth: 56,
          fit: BoxFit.cover,
          placeholderColor: Theme.of(context).colorScheme.surfaceContainer,
        ),
      ),
    );
  }
}
