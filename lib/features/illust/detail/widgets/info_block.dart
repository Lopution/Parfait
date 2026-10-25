import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/clipboard.dart';
import '../../../../app/format/app_format.dart';
import '../../../../app/navigation/routes.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/author_summary.dart';
import '../../../../app/widgets/edge_icon_buttons.dart';
import '../../../../app/widgets/feed/feed_text_warmup.dart';
import '../../../../app/widgets/follow_switch_button.dart';
import '../../../../app/widgets/person_card.dart';
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

/// The work's title, marks and stats, author, caption, tags and facts: one
/// sliver list, so a part below the first screen is built as it scrolls
/// near rather than with the page. Built parts stay built ([_KeptPart]).
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
        _KeptPart(
          child: Padding(
            padding: _margin.copyWith(top: FuncSpacing.sm),
            child: _MarksAndStats(entity: entity),
          ),
        ),
        _KeptPart(
          child: Padding(
            padding: _margin.copyWith(top: FuncSpacing.md),
            child: _Author(entity: entity),
          ),
        ),
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
        // Each fact pads its text by [_FactsRow.inset]; the row starts
        // that much short of the margin, so every wrapped line's first
        // text sits on it. Above, the tags' hit margin adds to the box.
        _KeptPart(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: FuncSpacing.lg - _FactsRow.inset.left,
            ),
            child: _FactsRow(entity: entity),
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

/// The author on a [PersonCard], name over @account, with a follow button
/// unless it is the signed-in user. The card shows the whole of it opens
/// the profile.
class _Author extends ConsumerWidget {
  const _Author({required this.entity});

  final IllustEntity entity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ownUserId = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent?.userId,
      ),
    );
    final author = entity.user;
    return LayoutBuilder(
      builder: (context, constraints) => PersonCard(
        key: const Key('illust-author-row'),
        onTap: () => openUser(context, author.id),
        tapHint: context.l10n.openAuthorProfile,
        trailing: author.id == ownUserId
            ? null
            // Capped at half the card so a long localized label leaves
            // the name a lane; the button scales its label down past it.
            : ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
                child: FollowSwitchButton(
                  userId: author.id,
                  userName: author.name,
                  userAccount: author.account,
                  compact: true,
                ),
              ),
        child: AuthorSummary(
          name: author.name,
          account: _handle(author),
          imageUrl: author.profileImageUrl,
          avatarRadius: 20,
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

/// One tonal label in the accent: AI-generated, R-18 or R-18G.
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

/// What the work is marked as and how it was received, under the title:
/// the marks (AI-generated, R-18, R-18G; only those it has), then views,
/// bookmarks and the full posting time, wrapping as whole items. Every
/// list payload carries these, so the line is complete on a neighbour
/// page before it is swiped in; the comment count only the detail API has
/// sits on the comments section. Screen readers hear one node: the marks,
/// then the stats as one sentence.
class _MarksAndStats extends StatelessWidget {
  const _MarksAndStats({required this.entity});

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
    final marks = [
      if (entity.isAi) _Mark(l10n.badgeAi),
      if (entity.isR18) const _Mark('R-18'),
      if (entity.isR18G) const _Mark('R-18G'),
    ];
    return MergeSemantics(
      key: const Key('illust-detail-stats'),
      child: Wrap(
        spacing: FuncSpacing.md,
        runSpacing: FuncSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (marks.isNotEmpty)
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: FuncSpacing.xs,
              children: marks,
            ),
          Semantics(
            label: date == null
                ? l10n.detailMetaCountsSemantics(views, bookmarks)
                : l10n.detailStatsSemantics(views, bookmarks, date),
            child: ExcludeSemantics(
              child: _Fact(
                icon: Icons.visibility_outlined,
                text: views,
                style: style,
              ),
            ),
          ),
          ExcludeSemantics(
            child: _Fact(
              icon: Icons.favorite_outline,
              text: bookmarks,
              style: style,
            ),
          ),
          if (date != null) ExcludeSemantics(child: Text(date, style: style)),
        ],
      ),
    );
  }
}

/// The work's facts, each behind its glyph, as the block's last line:
/// size, pages (two or more), the software it was made with, and the ID,
/// which a tap copies — users quote artwork IDs. Wraps as whole facts.
class _FactsRow extends StatelessWidget {
  const _FactsRow({required this.entity});

  final IllustEntity entity;

  /// The box around each fact's text. The ID's target is that box: 8dp
  /// past its text up and down, 32dp in all with the 16dp line (a full
  /// 48dp would push the line away from the tags). The other facts take
  /// the same box, so every wrapped line has the same height and starts
  /// its text on the margin.
  static const inset = EdgeInsets.symmetric(
    horizontal: FuncSpacing.xs,
    vertical: FuncSpacing.sm,
  );

  @override
  Widget build(BuildContext context) {
    final style = _metaStyle(context);
    Widget boxed(Widget fact) => Padding(padding: inset, child: fact);
    return Wrap(
      key: const Key('illust-detail-facts'),
      // With the boxes, 12dp between two facts' text.
      spacing: FuncSpacing.md - inset.horizontal,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        boxed(
          _Fact(
            icon: Icons.aspect_ratio,
            text: '${entity.width}×${entity.height}',
            style: style,
          ),
        ),
        if (entity.pageCount > 1)
          boxed(
            _Fact(
              icon: Icons.collections_outlined,
              text: context.l10n.detailPageCount(entity.pageCount),
              style: style,
            ),
          ),
        if (entity.tools.isNotEmpty)
          Semantics(
            label: context.l10n.detailTools,
            child: boxed(
              _Fact(
                icon: Icons.brush_outlined,
                text: entity.tools.join(' / '),
                style: style,
              ),
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

/// "# 123" with a copy glyph. The ink and the target are the fact's box
/// ([_FactsRow.inset]).
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
          padding: _FactsRow.inset,
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
