import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/clipboard.dart';
import '../../../../app/format/app_format.dart';
import '../../../../app/navigation/routes.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/author_row.dart';
import '../../../../app/widgets/edge_icon_buttons.dart';
import '../../../../app/widgets/follow_switch_button.dart';
import '../../../../app/widgets/tag_chips.dart';
import '../../../../core/auth/account_store.dart';
import '../../../../core/entity/illust_entity.dart';
import '../../../../core/mute/mute_store.dart';
import '../../../../l10n/context.dart';
import '../../../../app/widgets/caption_rich_text.dart';
import '../../../../app/widgets/inline_translation.dart';
import '../../../../app/widgets/tag_actions_sheet.dart';
import '../../../../core/entity/illust_caption.dart';
import 'detail_section_header.dart';

/// The page margin of the info area.
const _margin = EdgeInsets.symmetric(horizontal: FuncSpacing.xl);

/// The margin of a row that ends in an icon button: its glyph, not its
/// target, ends on the margin (LAYOUT-15).
const _buttonRowMargin = EdgeInsetsDirectional.only(
  start: FuncSpacing.xl,
  end: FuncSpacing.xl - EdgeIconButtons.glyphInset,
);

Widget _inMargin(Widget child) => Padding(padding: _margin, child: child);

/// The work's title, facts, author, caption and tags: one sliver list,
/// so a part below the first screen is built as it scrolls near rather
/// than with the page. Built parts stay built ([_KeptPart]).
class InfoBlock extends StatelessWidget {
  const InfoBlock({
    super.key,
    required this.entity,
    required this.blockMode,
    required this.onToggleBlockMode,
    this.anchorKey,
  });

  final IllustEntity entity;
  final bool blockMode;
  final VoidCallback onToggleBlockMode;

  /// Marks the first part, from the top of the block: the menu's
  /// artwork-info item scrolls to it.
  final GlobalKey? anchorKey;

  /// Collapsed caption height; longer captions get a Show more toggle.
  static const captionLines = 4;

  @override
  Widget build(BuildContext context) {
    // Sections pad themselves: a heading row that ends in a button ends
    // its padding short of the margin (LAYOUT-15). The next section of the
    // page spaces itself from the last one here.
    return SliverList.list(
      children: [
        _KeptPart(
          key: anchorKey,
          child: Padding(
            padding: const EdgeInsets.only(top: FuncSpacing.xl),
            // Official client order: the work title leads the meta block,
            // wraps without a line cap, and stays selectable — a one-line
            // AppBar title could only ellipsise. Without a caption the
            // title carries the translate button.
            child: entity.caption.isEmpty
                ? Padding(
                    padding: _buttonRowMargin,
                    child: _TranslatableTitle(title: entity.title),
                  )
                : _inMargin(_Title(title: entity.title)),
          ),
        ),
        // The line's ID target reaches [_MetaLine.targetInset] above and
        // below its text; the gap under it takes that much less.
        _KeptPart(
          child: Padding(
            padding: _margin.copyWith(
              bottom: FuncSpacing.lg - _MetaLine.targetInset,
            ),
            child: _MetaLine(entity: entity),
          ),
        ),
        _KeptPart(
          child: Padding(
            padding: _margin.copyWith(bottom: FuncSpacing.md),
            child: _StatsBlock(entity: entity),
          ),
        ),
        _KeptPart(child: _inMargin(_AuthorBlock(entity: entity))),
        if (entity.caption.isNotEmpty)
          _KeptPart(
            key: const Key('illust-detail-caption'),
            child: _CaptionSection(entity: entity),
          ),
        _KeptPart(
          key: const Key('illust-detail-tags'),
          child: _TagsSection(
            entity: entity,
            blockMode: blockMode,
            onToggleBlockMode: onToggleBlockMode,
          ),
        ),
      ],
    );
  }
}

/// Keeps a part of the block built once it has been, as the block was
/// when it was one box: a part holds state (a translation, an expanded
/// caption) that scrolling away must not lose.
class _KeptPart extends StatefulWidget {
  const _KeptPart({super.key, required this.child});

  final Widget child;

  @override
  State<_KeptPart> createState() => _KeptPartState();
}

class _KeptPartState extends State<_KeptPart>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// The author on the block surface, with a follow button unless it is the
/// signed-in user.
class _AuthorBlock extends ConsumerWidget {
  const _AuthorBlock({required this.entity});

  final IllustEntity entity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ownUserId = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent?.userId,
      ),
    );
    final author = entity.user;
    return _BlockSurface(
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
    );
  }
}

/// The tags, each searching on a tap or, in the block mode, muting.
class _TagsSection extends ConsumerWidget {
  const _TagsSection({
    required this.entity,
    required this.blockMode,
    required this.onToggleBlockMode,
  });

  final IllustEntity entity;
  final bool blockMode;
  final VoidCallback onToggleBlockMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Tag chips now block through the MuteStore: tag mutes sync with the
    // official /v1/mute list instead of the legacy local-only pref.
    final mutedTags = ref.watch(muteStoreProvider.select((s) => s.tags));
    final muteStore = ref.read(muteStoreProvider.notifier);
    return _Section(
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
                    toggleTagMute(
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
              onLongPress: () => unawaited(
                showTagActionsSheet(
                  context,
                  tag: tag.name,
                  muted: mutedTags.contains(tag.name),
                  onSearch: () => openTagSearch(context, tag.name),
                  onToggleMute: () => unawaited(
                    toggleTagMute(
                      context,
                      muteStore,
                      tag.name,
                      muted: mutedTags.contains(tag.name),
                    ),
                  ),
                  onMuteMode: onToggleBlockMode,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The line under the title: when, how many pages, how large, and the
/// ID, which a tap copies — users quote artwork IDs. One line where it
/// fits; the ID wraps to the next as a whole.
class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.entity});

  final IllustEntity entity;

  /// How far the ID's target reaches past its text, up and down: 32dp in
  /// all with the 16dp line. A full 48dp would push the line away from
  /// the title.
  static const targetInset = FuncSpacing.sm;

  static const _separator = ' · ';

  @override
  Widget build(BuildContext context) {
    final style = _metaStyle(context);
    final created = DateTime.tryParse(entity.createDate ?? '');
    final facts = [
      if (created != null) AppFormat.date(context, created),
      if (entity.pageCount > 1) context.l10n.detailPageCount(entity.pageCount),
      '${entity.width}×${entity.height}',
    ];
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '${facts.join(_separator)}$_separator',
          key: const Key('illust-detail-meta'),
          style: style,
        ),
        _CopyableId(id: entity.id, style: style),
      ],
    );
  }
}

/// "ID 123" with a copy glyph. The ink is the small box around the two;
/// the target reaches [_MetaLine.targetInset] past the text on each side.
class _CopyableId extends StatelessWidget {
  const _CopyableId({required this.id, required this.style});

  final int id;
  final TextStyle style;

  /// Sized to the metadata text rather than the 24dp default.
  static const _copyGlyph = 14.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Tooltip(
      message: l10n.copyArtworkId,
      child: InkWell(
        key: const Key('illust-detail-id'),
        borderRadius: FuncShape.badge,
        onTap: () => unawaited(
          copyToClipboard(context, '$id', message: l10n.artworkIdCopied),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FuncSpacing.xs,
            vertical: _MetaLine.targetInset,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('ID $id', style: style),
              const SizedBox(width: FuncSpacing.xs),
              Icon(Icons.content_copy, size: _copyGlyph, color: style.color),
            ],
          ),
        ),
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

/// The work title: large, wrapping without a line cap, selectable.
class _Title extends StatelessWidget {
  const _Title({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => SelectableText(
    title,
    style: Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
  );
}

/// The title of a work without a caption, with the translate button at its
/// end and the translation below.
class _TranslatableTitle extends ConsumerStatefulWidget {
  const _TranslatableTitle({required this.title});

  final String title;

  @override
  ConsumerState<_TranslatableTitle> createState() => _TranslatableTitleState();
}

class _TranslatableTitleState extends ConsumerState<_TranslatableTitle>
    with InlineTranslation {
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _Title(title: widget.title)),
          TranslateIconButton(
            translating: translating,
            shown: translationShown,
            onPressed: () => unawaited(toggleTranslation([widget.title])),
          ),
        ],
      ),
      // The row's padding ends short for the button's glyph; the
      // translation below ends on the margin like the text.
      Padding(
        padding: const EdgeInsetsDirectional.only(
          end: EdgeIconButtons.glyphInset,
        ),
        child: TranslationPanel(
          translating: translating,
          translations: translations,
          failure: translationFailure,
        ),
      ),
    ],
  );
}

/// The caption section. Its translate button translates the title and the
/// caption together and shows both below the caption.
class _CaptionSection extends ConsumerStatefulWidget {
  const _CaptionSection({required this.entity});

  final IllustEntity entity;

  @override
  ConsumerState<_CaptionSection> createState() => _CaptionSectionState();
}

class _CaptionSectionState extends ConsumerState<_CaptionSection>
    with InlineTranslation {
  @override
  Widget build(BuildContext context) {
    final entity = widget.entity;
    return _Section(
      heading: context.l10n.detailSectionCaption,
      action: TranslateIconButton(
        translating: translating,
        shown: translationShown,
        onPressed: () => unawaited(
          toggleTranslation([
            entity.title,
            ?_nonBlank(captionPlainText(entity.caption)),
          ]),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Pixiv captions are HTML; render them immediately so the
          // detail content is complete on the same frame as the artwork.
          CaptionRichText(
            caption: entity.caption,
            maxLines: InfoBlock.captionLines,
          ),
          TranslationPanel(
            translating: translating,
            translations: translations,
            failure: translationFailure,
            emphasizeFirst: true,
          ),
        ],
      ),
    );
  }
}

String? _nonBlank(String text) => text.trim().isEmpty ? null : text;

/// One titled part of the info area: a [DetailSectionHeader] like the
/// sections below the block, then its content in the margin.
class _Section extends StatelessWidget {
  const _Section({required this.heading, required this.child, this.action});

  final String heading;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DetailSectionHeader(title: heading, action: action),
      _inMargin(child),
    ],
  );
}
