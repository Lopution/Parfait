import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/format/app_format.dart';
import '../../../../app/haptics/app_haptics.dart';
import '../../../../app/motion/app_overlays.dart';
import '../../../../app/navigation/routes.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/errors/error_details.dart';
import '../../../../app/widgets/author_row.dart';
import '../../../../app/widgets/follow_switch_button.dart';
import '../../../../app/widgets/tag_chips.dart';
import '../../../../app/widgets/unmute_undo.dart';
import '../../../../core/auth/account_store.dart';
import '../../../../core/entity/illust_entity.dart';
import '../../../../core/mute/mute_models.dart';
import '../../../../core/mute/mute_store.dart';
import '../../../../l10n/context.dart';
import '../../../../app/widgets/caption_rich_text.dart';
import '../../../../app/clipboard.dart';

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

  /// Collapsed caption height; longer captions get a Show more toggle.
  static const captionLines = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;

    // Tag chips now block through the MuteStore: tag mutes sync with the
    // official /v1/mute list instead of the legacy local-only pref.
    final mutedTags = ref.watch(muteStoreProvider.select((s) => s.tags));
    final muteStore = ref.read(muteStoreProvider.notifier);
    final ownUserId = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent?.userId,
      ),
    );
    final author = entity.user;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FuncSpacing.xl,
        vertical: FuncSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Official client order: the work title
          // leads the meta block, wraps without a line cap, and stays
          // selectable — a one-line AppBar title could only ellipsise.
          SelectableText(
            entity.title,
            style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: FuncSpacing.sm),
          AuthorRow(
            key: const Key('illust-author-row'),
            userId: author.id,
            name: author.name,
            avatarUrl: author.profileImageUrl,
            trailing: author.id == ownUserId
                ? null
                : FollowSwitchButton(
                    userId: author.id,
                    userName: author.name,
                    userAccount: author.account,
                    compact: true,
                  ),
          ),
          const SizedBox(height: FuncSpacing.sm),
          _MetaLine(entity: entity),
          if (entity.caption.isNotEmpty) ...[
            const SizedBox(height: FuncSpacing.lg),
            // Pixiv captions are HTML; render them immediately so the detail
            // content is complete on the same frame as the artwork.
            CaptionRichText(caption: entity.caption, maxLines: captionLines),
          ],
          const SizedBox(height: FuncSpacing.lg),
          TagChips(
            children: [
              for (final tag in entity.tags)
                TagChip(
                  label: tag.name,
                  translated: tag.translatedName,
                  blockMode: blockMode,
                  blocked: mutedTags.contains(tag.name),
                  onTap: () {
                    if (blockMode) {
                      unawaited(
                        _toggleTagMute(
                          context,
                          muteStore,
                          tag.name,
                          muted: mutedTags.contains(tag.name),
                        ),
                      );
                    } else {
                      openTagSearch(context, tag.name);
                    }
                  },
                  // Long-press opens the direct action menu (search /
                  // copy / mute / batch-mute entry) instead of silently
                  // flipping the block mode.
                  onLongPress: () => _showTagActions(
                    context,
                    ref,
                    tag,
                    muted: mutedTags.contains(tag.name),
                  ),
                ),
            ],
          ),
          const SizedBox(height: FuncSpacing.lg),
          // ID stays selectable: users quote artwork IDs. SelectableText,
          // not SelectionArea — SelectionArea pulls in the whole
          // SelectableRegion/context-menu machinery (~180KB AOT) that
          // nothing else in the app uses, while SelectableText is already
          // compiled in for the title.
          SelectableText(
            '${entity.width}×${entity.height} · ID ${entity.id}',
            key: const Key('illust-detail-footer'),
            style: _metaStyle(context),
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

  /// Direct tag action menu (R3): search, copy, mute/unmute, and the entry
  /// into the batch mute mode. `TagChip`'s signature stays unchanged — the
  /// menu is call-site behavior, not a chip variant.
  void _showTagActions(
    BuildContext context,
    WidgetRef ref,
    IllustTag tag, {
    required bool muted,
  }) {
    AppHaptics.longPress();
    final l10n = context.l10n;
    unawaited(
      showAppBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.search),
                  title: Text(l10n.tagActionSearch),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    openTagSearch(context, tag.name);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy_outlined),
                  title: Text(l10n.tagActionCopy),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(
                      copyToClipboard(
                        context,
                        tag.name,
                        message: l10n.tagCopied,
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: Icon(
                    muted
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  title: Text(
                    muted ? l10n.tagActionUnmute : l10n.tagActionMute,
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(
                      _toggleTagMute(
                        context,
                        ref.read(muteStoreProvider.notifier),
                        tag.name,
                        muted: muted,
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add_check),
                  title: Text(l10n.tagActionMuteMode),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    onToggleBlockMode();
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The secondary metadata tier: the theme's small body text, tabular.
TextStyle _metaStyle(BuildContext context) {
  final theme = Theme.of(context);
  return theme.textTheme.bodySmall!
      .copyWith(color: theme.colorScheme.onSurfaceVariant)
      .tabular;
}

/// Date · views · bookmarks on one line in the theme's own scale. A narrow
/// screen or a long translation wraps it rather than dropping the date.
/// Screen readers hear one sentence; the icons are not read.
class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.entity});

  final IllustEntity entity;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final style = _metaStyle(context);
    final createDate = DateTime.tryParse(entity.createDate ?? '');
    final date = createDate == null
        ? null
        : AppFormat.date(context, createDate);
    final views = AppFormat.count(context, entity.totalView);
    final bookmarks = AppFormat.count(context, entity.totalBookmarks);
    InlineSpan icon(IconData data) => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Icon(data, size: style.fontSize, color: style.color),
    );
    return Semantics(
      container: true,
      label: date == null
          ? l10n.detailMetaCountsSemantics(views, bookmarks)
          : l10n.detailMetaSemantics(date, views, bookmarks),
      child: ExcludeSemantics(
        child: Text.rich(
          key: const Key('illust-detail-meta'),
          TextSpan(
            children: [
              if (date != null) TextSpan(text: '$date · '),
              icon(Icons.remove_red_eye_outlined),
              TextSpan(text: ' $views · '),
              icon(Icons.favorite_border),
              TextSpan(text: ' $bookmarks'),
            ],
          ),
          style: style,
        ),
      ),
    );
  }
}

/// Mutes or unmutes [tag]; a failure shows the error, a landed unmute
/// offers Undo.
Future<void> _toggleTagMute(
  BuildContext context,
  MuteStore store,
  String tag, {
  required bool muted,
}) async {
  try {
    await store.toggleTag(tag);
  } on Object catch (error) {
    if (context.mounted) {
      showErrorSnackBar(context, action: context.l10n.muteFailed, error: error);
    }
    return;
  }
  if (muted && context.mounted) showUnmuteUndo(context, MuteKey.tag(tag));
}
