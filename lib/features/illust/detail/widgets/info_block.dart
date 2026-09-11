import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/navigation/routes.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/author_summary.dart';
import '../../../../app/widgets/tag_chips.dart';
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
    final tokens = FuncSemanticTokens.of(context);
    final textTheme = Theme.of(context).textTheme;
    final blockedTags = ref.watch(blockedTagsProvider);
    final blockedController = ref.read(blockedTagsProvider.notifier);
    final createDate = DateTime.tryParse(entity.createDate ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FuncSpacing.xl,
        vertical: FuncSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The whole author block opens the user page; AuthorSummary owns
          // the row so the 48px avatar slot and key stay stable.
          AuthorSummary(
            name: entity.user.name,
            account: entity.user.account,
            imageUrl: entity.user.profileImageUrl,
            avatarKey: const Key('illust-author-avatar'),
            onTap: () => openUser(context, entity.user.id),
          ),
          const SizedBox(height: FuncSpacing.lg),
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
              const SizedBox(width: FuncSpacing.md),
              _StatItem(
                icon: Icons.remove_red_eye_outlined,
                label: '${entity.totalView}',
              ),
              const SizedBox(width: FuncSpacing.sm),
              _StatItem(
                icon: Icons.favorite_border,
                label: '${entity.totalBookmarks}',
              ),
            ],
          ),
          const SizedBox(height: FuncSpacing.xs),
          Row(
            children: [
              Text(
                context.l10n.illustDetailSize(entity.width, entity.height),
                style: textTheme.bodyMedium,
              ),
              const SizedBox(width: FuncSpacing.xs),
              Text(
                'ID: ${entity.id}',
                style: tokens.numeric.copyWith(color: tokens.contentSecondary),
              ),
            ],
          ),
          if (entity.caption.isNotEmpty) ...[
            const SizedBox(height: FuncSpacing.md),
            // Pixiv captions are HTML; render them immediately so the detail
            // content is complete on the same frame as the artwork.
            Padding(
              padding: const EdgeInsets.only(bottom: FuncSpacing.lg),
              child: CaptionRichText(caption: entity.caption),
            ),
          ],
          const SizedBox(height: FuncSpacing.lg),
          TagChips(
            children: [
              for (final tag in entity.tags)
                TagChip(
                  label: tag.name,
                  translated: tag.translatedName,
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
          const SizedBox(height: FuncSpacing.lg),
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
    final tokens = FuncSemanticTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: tokens.contentSecondary),
        const SizedBox(width: FuncSpacing.xs),
        Text(label, style: tokens.numeric),
      ],
    );
  }
}
