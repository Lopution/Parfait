import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/mute/mute_predicate.dart';
import '../../../core/mute/mute_store.dart';
import '../../../l10n/context.dart';
import '../../motion/app_overlays.dart';
import '../../pixiv_image.dart';
import '../../theme/func_semantic_tokens.dart';
import '../display_actions.dart';
import '../feed/feed_selection.dart';
import '../feed/muted_cover.dart';
import 'card_action.dart';
import 'illust_card_actions.dart';
import 'ios_card_context_menu.dart';
import '../../icons/app_icons.dart';
import '../../icons/ui_icons.dart';

/// The card's secondary click on a pointer: the registered [CardAction]s as a
/// context menu beside the pointer (R11). On touch or stylus the same call
/// falls back to the long-press sheet, so a pen's right-click keeps the
/// bottom panel.
Future<void> showCardActionsMenu(
  BuildContext context,
  IllustEntity entity,
  Offset position, {
  PointerDeviceKind? kind,
}) {
  final providers = ProviderScope.containerOf(context);
  final state = CardActionState.ofContainer(providers);
  final navigator = Navigator.of(context).context;
  final l10n = context.l10n;
  return showDisplayActions(
    context,
    position: position,
    kind: kind,
    onLongPress: () => unawaited(showCardActionSheet(context, entity)),
    actions: [
      for (final action in providers.read(illustCardActionsProvider))
        DisplayAction(
          icon: action.iconFor(state, entity),
          label: action.labelFor(state, entity, l10n),
          onSelected: () => unawaited(
            action.run(
              context.mounted ? context : navigator,
              providers,
              entity,
            ),
          ),
        ),
    ],
  );
}

/// Card long-press menu: names the work at the top, then renders the
/// registered [CardAction]s as a frosted preview context menu on iOS, or an
/// adaptive overlay (dialog/popover on wide pointer viewports, bottom sheet on
/// touch/narrow) elsewhere.
Future<void> showCardActionSheet(BuildContext context, IllustEntity entity) {
  if (Theme.of(context).platform == TargetPlatform.iOS) {
    return showIosCardContextMenu(context, entity);
  }
  // The actions run on the card's context. A refresh landing under the
  // open sheet can take the card away: they run on its Navigator's then,
  // which outlives the card and the sheet.
  final navigator = Navigator.of(context).context;
  final selection = FeedSelectionScope.maybeOf(context);
  final canSelect =
      selection != null && selection.enabled && !selection.hasSelection;
  return showAppAdaptiveDialog<void>(
    context: context,
    maxWidth: 420,
    // Sized to its content: the header plus every action stays in view
    // instead of being cut at the default 9/16 cap; content taller than
    // the screen still scrolls.
    isScrollControlled: true,
    builder: (sheetContext) => Consumer(
      builder: (sheetContext, ref, _) {
        final actions = ref.watch(illustCardActionsProvider);
        final state = CardActionState.ofRef(ref);
        final providers = ProviderScope.containerOf(sheetContext);
        final l10n = sheetContext.l10n;
        final wide = useWideOverlay(sheetContext);
        return SafeArea(
          top: false,
          // The sheet announces which work its actions apply to.
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            label: entity.title,
            child: ListView(
              shrinkWrap: true,
              // Scrolls only when it overflows; compact sheets attach to
              // smooth_sheets' PrimaryScrollController so scrolling back to top
              // drags the sheet closed cleanly.
              primary: !wide,
              physics: const ClampingScrollPhysics(),
              children: [
                _SheetHeader(
                  entity,
                  onClose: wide
                      ? () => Navigator.of(sheetContext).maybePop()
                      : null,
                ),
                if (wide)
                  Divider(
                    height: 1,
                    color: FuncSemanticTokens.of(sheetContext).divider,
                  ),
                if (canSelect)
                  Semantics(
                    button: true,
                    label: l10n.cardActionSelect,
                    child: ListTile(
                      leading: const Icon(UiIcons.checklist),
                      title: Text(l10n.cardActionSelect),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        selection.toggle(entity.id);
                      },
                    ),
                  ),
                for (final action in actions)
                  Semantics(
                    button: true,
                    label: action.labelFor(state, entity, l10n),
                    child: ListTile(
                      leading: Icon(action.iconFor(state, entity)),
                      title: Text(action.labelFor(state, entity, l10n)),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(
                          action.run(
                            context.mounted ? context : navigator,
                            providers,
                            entity,
                          ),
                        );
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
  const _SheetHeader(this.entity, {this.onClose});

  static const double thumbnailSize = 48;

  final IllustEntity entity;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final muted =
        ref.watch(
              effectiveMutesProvider.select((s) => muteHitFor(entity, s)),
            ) !=
            null &&
        !ref.watch(
          revealedMuteIdsProvider.select((ids) => ids.contains(entity.id)),
        );
    final url = entity.squareUrlAt(0);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        onClose != null ? FuncSpacing.sm : FuncSpacing.lg,
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
                        muted ? AppIcons.eyeOff : AppIcons.illust,
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
          if (onClose != null) ...[
            const SizedBox(width: FuncSpacing.xs),
            IconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: onClose,
              icon: const Icon(UiIcons.close),
            ),
          ],
        ],
      ),
    );
  }
}
