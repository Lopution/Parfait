import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/mute/mute_predicate.dart';
import '../../../core/mute/mute_store.dart';
import '../../../l10n/context.dart';
import '../../motion/app_overlays.dart';
import '../../pixiv_image.dart';
import '../../theme/func_semantic_tokens.dart';
import '../feed/muted_cover.dart';
import 'illust_card_actions.dart';

/// Card long-press menu: names the work at the top, then renders the
/// registered [CardAction]s as a modal bottom sheet. Presentation curve and
/// reduced-motion degrade come from [showAppBottomSheet] / MotionTokens.
Future<void> showCardActionSheet(BuildContext context, IllustEntity entity) {
  return showAppBottomSheet<void>(
    context: context,
    // Sized to its content: the header plus every action stays in view
    // instead of being cut at the default 9/16 cap; content taller than
    // the screen still scrolls.
    isScrollControlled: true,
    builder: (sheetContext) => Consumer(
      builder: (sheetContext, ref, _) {
        final actions = ref.watch(illustCardActionsProvider);
        final l10n = sheetContext.l10n;
        return SafeArea(
          top: false,
          // The sheet announces which work its actions apply to.
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            label: entity.title,
            child: ListView(
              shrinkWrap: true,
              children: [
                _SheetHeader(entity),
                for (final action in actions)
                  Semantics(
                    button: true,
                    label: action.labelFor(ref, entity, l10n),
                    child: ListTile(
                      leading: Icon(action.iconFor(ref, entity)),
                      title: Text(action.labelFor(ref, entity, l10n)),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        action.run(context, ref, entity);
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// Thumbnail, title and author of the work the actions apply to. A work the
/// card shows blurred (muted, not revealed) keeps its image hidden here.
class _SheetHeader extends ConsumerWidget {
  const _SheetHeader(this.entity);

  static const double thumbnailSize = 48;

  final IllustEntity entity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final muted =
        ref.watch(muteStoreProvider.select((s) => muteHitFor(entity, s))) !=
            null &&
        !ref.watch(
          revealedMuteIdsProvider.select((ids) => ids.contains(entity.id)),
        );
    final url = entity.squareUrlAt(0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.lg,
        FuncSpacing.sm,
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: FuncShape.control,
            child: SizedBox.square(
              dimension: thumbnailSize,
              child: muted || url == null
                  ? ColoredBox(
                      color: colors.surfaceContainerHighest,
                      child: Icon(
                        muted
                            ? Icons.visibility_off_outlined
                            : Icons.image_outlined,
                        color: colors.onSurfaceVariant,
                      ),
                    )
                  : PixivImage.feed(url, layoutWidth: thumbnailSize),
            ),
          ),
          const SizedBox(width: FuncSpacing.md),
          Expanded(
            child: MergeSemantics(
              child: Semantics(
                header: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entity.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.title,
                    ),
                    Text(
                      entity.user.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.caption,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
