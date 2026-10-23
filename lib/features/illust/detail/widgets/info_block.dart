import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/clipboard.dart';
import '../../../../app/format/app_format.dart';
import '../../../../app/navigation/routes.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/author_row.dart';
import '../../../../app/widgets/author_summary.dart';
import '../../../../app/widgets/edge_icon_buttons.dart';
import '../../../../app/widgets/feed/feed_text_warmup.dart';
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

/// The page margin of the info area, the app's (LAYOUT-14).
const _margin = EdgeInsets.symmetric(horizontal: FuncSpacing.lg);

/// The margin of a row that ends in an icon button: its glyph, not its
/// target, ends on the margin (LAYOUT-15).
const _buttonRowMargin = EdgeInsetsDirectional.only(
  start: FuncSpacing.lg,
  end: FuncSpacing.lg - EdgeIconButtons.glyphInset,
);

Widget _inMargin(Widget child) => Padding(padding: _margin, child: child);

/// The author's "@account" line, if the work names one.
String? _handle(IllustUser author) =>
    author.account.isEmpty ? null : '@${author.account}';

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

  /// The title, author and tag lines exactly as the block lays them out
  /// for [entity] under [context], for [FeedTextWarmup]: the text a
  /// detail page shapes in the frame that builds it.
  static List<WarmText> warmTexts(BuildContext context, IllustEntity entity) =>
      [
        _Title.warmText(context, entity.title),
        ...AuthorSummary.warmTexts(
          context,
          name: entity.user.name,
          account: _handle(entity.user),
        ),
        for (final tag in entity.tags)
          TagChip.warmText(
            context,
            label: tag.name,
            translated: tag.translatedName,
          ),
      ];

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
            padding: const EdgeInsets.only(top: FuncSpacing.lg),
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
        if (entity.isAi || entity.isR18 || entity.isR18G)
          _KeptPart(
            child: Padding(
              padding: _margin.copyWith(top: FuncSpacing.sm),
              child: _Marks(entity: entity),
            ),
          ),
        _KeptPart(
          child: Padding(
            padding: _margin.copyWith(top: FuncSpacing.sm),
            child: _StatsLine(entity: entity),
          ),
        ),
        // The ID's target reaches [_FactsRow.targetInset] above and below
        // its text; the gaps around the row take that much less.
        _KeptPart(
          child: Padding(
            padding: _margin.copyWith(
              top: FuncSpacing.xs - _FactsRow.targetInset / 2,
              bottom: FuncSpacing.sm - _FactsRow.targetInset / 2,
            ),
            child: _FactsRow(entity: entity),
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

/// The author, name over @account, with a follow button unless it is the
/// signed-in user. No card: it reads as one more row of the page.
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
    return AuthorRow(
      key: const Key('illust-author-row'),
      userId: author.id,
      name: author.name,
      account: _handle(author),
      avatarUrl: author.profileImageUrl,
      avatarRadius: 20,
      trailing: author.id == ownUserId
          ? null
          : FollowSwitchButton(
              userId: author.id,
              userName: author.name,
              userAccount: author.account,
              compact: true,
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

/// What the work is marked as: AI-generated, R-18 or R-18G, each on a
/// tonal label in the accent.
class _Marks extends StatelessWidget {
  const _Marks({required this.entity});

  final IllustEntity entity;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: FuncSpacing.xs,
    runSpacing: FuncSpacing.xs,
    children: [
      if (entity.isAi) _Mark(context.l10n.badgeAi),
      if (entity.isR18) const _Mark('R-18'),
      if (entity.isR18G) const _Mark('R-18G'),
    ],
  );
}

class _Mark extends StatelessWidget {
  const _Mark(this.label);

  final String label;

  /// The tint of the label's ground: the accent, faint.
  static const _groundAlpha = 0.12;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: _groundAlpha),
        borderRadius: FuncShape.badge,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FuncSpacing.sm,
          vertical: FuncSpacing.xxs,
        ),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: accent,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// How the work was received and when it came out: views, bookmarks and
/// the full posting time. Every list payload carries the counts, so the
/// line is complete on a neighbour page before it is swiped in; the
/// comment count only the detail API has sits on the comments section.
/// Screen readers hear one sentence.
class _StatsLine extends StatelessWidget {
  const _StatsLine({required this.entity});

  final IllustEntity entity;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final style = _metaStyle(context);
    final views = AppFormat.count(context, entity.totalView);
    final bookmarks = AppFormat.count(context, entity.totalBookmarks);
    final created = DateTime.tryParse(entity.createDate ?? '');
    final date = created == null
        ? null
        : AppFormat.date(context, created, withTime: true);
    return Semantics(
      key: const Key('illust-detail-stats'),
      container: true,
      label: date == null
          ? l10n.detailMetaCountsSemantics(views, bookmarks)
          : l10n.detailStatsSemantics(views, bookmarks, date),
      child: ExcludeSemantics(
        child: Wrap(
          spacing: FuncSpacing.md,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _Fact(icon: Icons.visibility_outlined, text: views, style: style),
            _Fact(icon: Icons.favorite_outline, text: bookmarks, style: style),
            if (date != null) Text(date, style: style),
          ],
        ),
      ),
    );
  }
}

/// The work's facts, each behind its glyph: size, pages (two or more),
/// the software it was made with, and the ID, which a tap copies — users
/// quote artwork IDs. Wraps as whole facts.
class _FactsRow extends StatelessWidget {
  const _FactsRow({required this.entity});

  final IllustEntity entity;

  /// How far the ID's target reaches past its text, up and down: 32dp in
  /// all with the 16dp line. A full 48dp would push the row away from the
  /// lines around it.
  static const targetInset = FuncSpacing.sm;

  @override
  Widget build(BuildContext context) {
    final style = _metaStyle(context);
    return Wrap(
      key: const Key('illust-detail-facts'),
      spacing: FuncSpacing.md,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Fact(
          icon: Icons.aspect_ratio,
          text: '${entity.width}×${entity.height}',
          style: style,
        ),
        if (entity.pageCount > 1)
          _Fact(
            icon: Icons.collections_outlined,
            text: context.l10n.detailPageCount(entity.pageCount),
            style: style,
          ),
        if (entity.tools.isNotEmpty)
          Semantics(
            label: context.l10n.detailTools,
            child: _Fact(
              icon: Icons.brush_outlined,
              text: entity.tools.join(' / '),
              style: style,
            ),
          ),
        _CopyableId(id: entity.id, style: style),
      ],
    );
  }
}

/// One fact: a small glyph in the text's colour, then the text.
class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text, required this.style});

  final IconData icon;
  final String text;
  final TextStyle style;

  /// Sized to the metadata text rather than the 24dp default.
  static const glyph = 14.0;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: glyph, color: style.color),
      const SizedBox(width: FuncSpacing.xs),
      Text(text, style: style),
    ],
  );
}

/// "# 123" with a copy glyph. The ink is the small box around them; the
/// target reaches [_FactsRow.targetInset] past the text on each side.
class _CopyableId extends StatelessWidget {
  const _CopyableId({required this.id, required this.style});

  final int id;
  final TextStyle style;

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
            vertical: _FactsRow.targetInset,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tag, size: _Fact.glyph, color: style.color),
              const SizedBox(width: FuncSpacing.xxs),
              Text('$id', style: style),
              const SizedBox(width: FuncSpacing.xs),
              Icon(Icons.content_copy, size: _Fact.glyph, color: style.color),
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

/// The work title: large, wrapping without a line cap, selectable.
class _Title extends StatelessWidget {
  const _Title({required this.title});

  final String title;

  static TextStyle? _style(BuildContext context) => Theme.of(
    context,
  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600);

  /// [title] as the [SelectableText] lays it out on the page's Material:
  /// an editable paragraph with a strut taken from its style, in the UI
  /// locale.
  static WarmText warmText(BuildContext context, String title) {
    final style = warmStyle(
      context,
      _style(context),
      inherited: Theme.of(context).textTheme.bodyMedium,
    );
    return (
      span: TextSpan(text: title, style: style),
      locale: Localizations.maybeLocaleOf(context),
      strutStyle: const StrutStyle().inheritFromTextStyle(style),
    );
  }

  @override
  Widget build(BuildContext context) =>
      SelectableText(title, style: _style(context));
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
