import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/entity/illust_entity.dart';
import '../../core/entity/illust_store.dart';
import '../../core/mute/mute_predicate.dart';
import '../../core/mute/mute_store.dart';
import '../../core/settings/local_block_filter.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import '../../core/user/user_store.dart';
import '../motion/press_scale.dart';
import '../navigation/routes.dart';
import '../pixiv_image.dart';
import '../theme/func_semantic_tokens.dart';
import 'author_summary.dart';
import 'follow_switch_button.dart';

/// A user and their recent works: who they are, a follow switch, and up to
/// three of their works (recommended users, artist search results). The
/// thumbnails sit outside the user row's ink so every tap lands on exactly
/// one target.
class UserPreviewRow extends ConsumerWidget {
  const UserPreviewRow({super.key, required this.entity});

  final UserEntity entity;

  /// The "@account" line, or null without an account.
  static String? handleOf(UserEntity user) =>
      user.account.isEmpty ? null : '@${user.account}';

  /// Preview works that may be shown: local R-18/AI blocks and mute hits
  /// are skipped outright — a blurred square this small says nothing.
  List<IllustEntity> _visiblePreviews(WidgetRef ref) {
    final ids = ref.watch(
      userPreviewIdsProvider.select((previews) => previews[entity.id]),
    );
    if (ids == null || ids.isEmpty) return const [];
    final settings = ref.watch(settingsProvider).value;
    final mutes = ref.watch(muteStoreProvider);
    return [
      for (final illust in ref.watch(illustStoreProvider).getAll(ids))
        if (!(settings != null &&
                isLocallyBlocked(
                  illust,
                  blockR18: settings.enableLocalBlockR18,
                  blockAI: settings.enableLocalBlockAI,
                )) &&
            muteHitFor(illust, mutes) == null)
          illust,
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final previews = _visiblePreviews(ref);
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: FuncSpacing.md,
        vertical: FuncSpacing.sm,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            button: true,
            child: InkWell(
              onTap: () => openUser(context, entity.id),
              child: Padding(
                padding: const EdgeInsets.all(FuncSpacing.md),
                child: LayoutBuilder(
                  builder: (context, constraints) => Row(
                    children: [
                      Expanded(
                        child: AuthorSummary(
                          name: entity.name,
                          account: handleOf(entity),
                          imageUrl: entity.profileImageUrl,
                          avatarRadius: 24,
                        ),
                      ),
                      const SizedBox(width: FuncSpacing.sm),
                      // Capped at half the row so a long localized label
                      // leaves the name a lane; the button scales its label
                      // down past that bound.
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth * 0.5,
                        ),
                        child: FollowSwitchButton(
                          userId: entity.id,
                          userName: entity.name,
                          userAccount: entity.account,
                          compact: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (previews.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FuncSpacing.md,
                0,
                FuncSpacing.md,
                FuncSpacing.md,
              ),
              child: _UserPreviewStrip(previews: previews),
            ),
        ],
      ),
    );
  }
}

/// Three equal square slots; fewer works keep their third of the width and
/// sit at the start.
class _UserPreviewStrip extends StatelessWidget {
  const _UserPreviewStrip({required this.previews});

  final List<IllustEntity> previews;

  static const _gap = FuncSpacing.xs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < UserRelationPage.previewLimit; i++) ...[
          if (i > 0) const SizedBox(width: _gap),
          Expanded(
            child: i < previews.length
                ? _UserPreviewThumbnail(entity: previews[i])
                : const SizedBox.shrink(),
          ),
        ],
      ],
    );
  }
}

class _UserPreviewThumbnail extends StatelessWidget {
  const _UserPreviewThumbnail({required this.entity});

  final IllustEntity entity;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      child: Semantics(
        container: true,
        button: true,
        label: entity.title,
        child: AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: FuncShape.control,
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                fit: StackFit.expand,
                children: [
                  PixivImage.feed(
                    entity.imageUrls.squareMedium,
                    layoutWidth: constraints.maxWidth,
                  ),
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: () =>
                          openIllust(context, entity.id, initialEntity: entity),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
