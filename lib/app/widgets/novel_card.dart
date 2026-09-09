import 'package:flutter/material.dart';

import '../../core/novel/novel_entity.dart';
import '../navigation/routes.dart';
import '../pixiv_image.dart';

/// Compact novel row card used by the New feed, profile novel tab and the
/// novel search results (three call sites — shared-component evidence).
class NovelCard extends StatelessWidget {
  const NovelCard({super.key, required this.entity});

  final NovelEntity entity;

  @override
  Widget build(BuildContext context) {
    return Card(
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
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
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

class _NovelCover extends StatelessWidget {
  const _NovelCover({required this.entity});

  final NovelEntity entity;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 68,
        height: 88,
        child: entity.coverImageUrl == null
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.menu_book_outlined),
              )
            : PixivImage.feed(
                entity.coverImageUrl!,
                layoutWidth: 68,
              ),
      ),
    );
  }
}
