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

  String? _postedDate(BuildContext context) {
    final created = DateTime.tryParse(entity.createDate ?? '');
    return created == null ? null : AppFormat.date(context, created);
  }

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
          if (_postedDate(context) case final date?) ...[
            const SizedBox(height: FuncSpacing.xs),
            Text(
              date,
              key: const Key('illust-detail-date'),
              style: _metaStyle(context),
            ),
          ],
          const SizedBox(height: FuncSpacing.lg),
          _StatsBlock(entity: entity),
          const SizedBox(height: FuncSpacing.md),
          _BlockSurface(
            padding: const EdgeInsetsDirectional.fromSTEB(
              FuncSpacing.md,
              FuncSpacing.sm,
              FuncSpacing.md,
              FuncSpacing.sm,
            ),
            child: AuthorRow(
              key: const Key('illust-author-row'),
              userId: author.id,
              name: author.name,
              avatarUrl: author.profileImageUrl,
              avatarRadius: 24,
              trailing: author.id == ownUserId
                  ? null
                  : FollowSwitchButton(
                      userId: author.id,
                      userName: author.name,
                      userAccount: author.account,
                      compact: true,
                    ),
            ),
          ),
          if (entity.caption.isNotEmpty)
            _Section(
              key: const Key('illust-detail-caption'),
              heading: context.l10n.detailSectionCaption,
              // Pixiv captions are HTML; render them immediately so the
              // detail content is complete on the same frame as the
              // artwork.
              child: CaptionRichText(
                caption: entity.caption,
                maxLines: captionLines,
              ),
            ),
          _Section(
            key: const Key('illust-detail-tags'),
            heading: context.l10n.detailSectionTags,
            child: TagChips(
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

/// The work's reception at a glance: views and bookmarks as large tabular
/// figures over small labels. Every list payload carries both, so the row
/// is complete on a neighbour page before it is swiped in; the comment
/// count only the detail API has sits on the comments section instead.
/// Screen readers hear one sentence.
class _StatsBlock extends StatelessWidget {
  const _StatsBlock({required this.entity});

  final IllustEntity entity;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final views = AppFormat.count(context, entity.totalView);
    final bookmarks = AppFormat.count(context, entity.totalBookmarks);
    return Semantics(
      key: const Key('illust-detail-stats'),
      container: true,
      label: l10n.detailMetaCountsSemantics(views, bookmarks),
      child: ExcludeSemantics(
        child: _BlockSurface(
          padding: const EdgeInsets.symmetric(
            horizontal: FuncSpacing.sm,
            vertical: FuncSpacing.md,
          ),
          child: Row(
            children: [
              _Stat(value: views, label: l10n.detailStatViews),
              _Stat(value: bookmarks, label: l10n.detailStatBookmarks),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          // A long compact count in a narrow column shrinks, never wraps.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: FuncSpacing.xxs),
          Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The neutral container the stats and author blocks stand on.
class _BlockSurface extends StatelessWidget {
  const _BlockSurface({required this.padding, required this.child});

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: FuncShape.card,
    ),
    child: Padding(padding: padding, child: child),
  );
}

/// One titled part of the info area: a heading, then its content.
class _Section extends StatelessWidget {
  const _Section({super.key, required this.heading, required this.child});

  final String heading;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: FuncSpacing.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(heading, style: Theme.of(context).textTheme.titleMedium),
        ),
        const SizedBox(height: FuncSpacing.sm),
        child,
      ],
    ),
  );
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
