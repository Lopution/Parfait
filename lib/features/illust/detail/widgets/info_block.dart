import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/navigation/routes.dart';
import '../../../../app/person_avatar.dart';
import '../../../../core/entity/illust_entity.dart';
import '../../../../core/settings/blocked_tags.dart';
import '../../../../l10n/context.dart';
import 'caption_rich_text.dart';

class InfoBlock extends ConsumerWidget {
  const InfoBlock({
    super.key,
    required this.entity,
    required this.blockMode,
    required this.onToggleBlockMode,
  });

  final IllustEntity entity;
  final bool blockMode;
  final VoidCallback onToggleBlockMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final blockedTags = ref.watch(blockedTagsProvider);
    final blockedController = ref.read(blockedTagsProvider.notifier);
    final createDate = DateTime.tryParse(entity.createDate ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The whole author block (avatar + name + account) opens the user
          // page. Wrapping happens outside the Row so the avatar keeps its
          // 48px slot and the existing key/spacing stay untouched.
          InkWell(
            onTap: () => openUser(context, entity.user.id),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox.square(
                  key: const Key('illust-author-avatar'),
                  dimension: 48,
                  child: PersonAvatar(
                    imageUrl: entity.user.profileImageUrl,
                    radius: 24,
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entity.user.name,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        entity.user.account,
                        style: textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // 日期行与统计行的排版（U2 一并整理）：日期占左侧，视线/收藏
          // 统计右侧成组，避免数字被日期挤压后换行错位。
          Row(
            children: [
              Expanded(
                child: Text(
                  createDate == null
                      ? context.l10n.illustDetailCreateDateUnknown
                      : context.l10n.illustDetailCreateDate(
                          '${createDate.year}/${createDate.month}/${createDate.day}',
                        ),
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 12),
              _StatItem(
                icon: Icons.remove_red_eye_outlined,
                label: '${entity.totalView}',
              ),
              const SizedBox(width: 10),
              _StatItem(
                icon: Icons.favorite_border,
                label: '${entity.totalBookmarks}',
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Text(
                context.l10n.illustDetailSize(entity.width, entity.height),
                style: textTheme.bodyMedium,
              ),
              const SizedBox(width: 5),
              Text('ID: ${entity.id}', style: textTheme.bodyMedium),
            ],
          ),
          if (entity.caption.isNotEmpty) ...[
            const SizedBox(height: 12),
            // Pixiv captions are HTML; render them immediately so the detail
            // content is complete on the same frame as the artwork.
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: CaptionRichText(caption: entity.caption),
            ),
          ],
          const SizedBox(height: 20),
          Wrap(
            children: [
              for (final tag in entity.tags)
                _TagChip(
                  tag: tag,
                  blockMode: blockMode,
                  blocked: blockedTags.contains(tag.name),
                  onTap: () {
                    if (blockMode) {
                      blockedController.toggle(tag.name);
                    } else {
                      openTagSearch(context, tag.name);
                    }
                  },
                  onLongPress: onToggleBlockMode,
                ),
            ],
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () => openIllustComments(context, entity.id),
            icon: const Icon(Icons.comment_outlined),
            label: Text(context.l10n.commentTitle),
          ),
        ],
      ),
    );
  }
}

/// One icon + numeric-stat pair in the detail meta row (U2 排版整理).
class _StatItem extends StatelessWidget {
  const _StatItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodyMedium;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12),
        const SizedBox(width: 4),
        Text(label, style: textStyle),
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.tag,
    required this.blockMode,
    required this.blocked,
    required this.onTap,
    required this.onLongPress,
  });

  final IllustTag tag;
  final bool blockMode;
  final bool blocked;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: theme.colorScheme.surface,
              ),
              child: Text(
                '#${tag.name}${tag.translatedName != null ? ' ${tag.translatedName}' : ''}',
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
          if (blockMode)
            Positioned(
              top: 0,
              right: 0,
              child: Icon(
                Icons.block,
                size: 15,
                color: blocked ? theme.colorScheme.primary : null,
              ),
            ),
        ],
      ),
    );
  }
}
