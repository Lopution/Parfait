import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/clipboard.dart';
import '../../../../app/format/app_format.dart';
import '../../../../app/layout/form_factor.dart';
import '../../../../app/layout/input_modality.dart';
import '../../../../app/navigation/route_facade.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/author_summary.dart';
import '../../../../app/widgets/edge_icon_buttons.dart';
import '../../../../app/widgets/feed/feed_text_warmup.dart';
import '../../../../app/widgets/follow_switch_button.dart';
import '../../../../app/widgets/meta_fact.dart';
import '../../../../app/widgets/middle_click_region.dart';
import '../../../../app/widgets/person_card.dart';
import '../../../../app/widgets/tag_chips.dart';
import '../../../../app/window/desktop_workspace_tabs.dart';
import '../../../../core/auth/account_store.dart';
import '../../../../core/entity/illust_entity.dart';
import '../../../../core/mute/mute_store.dart';
import '../../../../core/search/search_models.dart';
import '../../../../core/settings/settings_controller.dart';
import '../../../../l10n/context.dart';
import '../../../../app/widgets/caption_rich_text.dart';
import '../../../../app/widgets/inline_translation.dart';
import '../../../../app/widgets/tag_actions_sheet.dart';
import '../../../../core/entity/illust_caption.dart';
import 'detail_section_header.dart';
import '../../../../app/icons/app_icons.dart';

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
    this.showAuthor = true,
  });

  final IllustEntity entity;
  final bool blockMode;
  final VoidCallback onToggleBlockMode;

  /// Marks the first part, from the top of the block: the menu's
  /// artwork-info item scrolls to it.
  final GlobalKey? anchorKey;

  /// Whether the inline author row renders inside the scrollable info list.
  /// Two-pane/tabletop layouts pin [DetailAuthorCard] above the scroll instead.
  final bool showAuthor;

  /// Collapsed caption height; longer captions get a Show more toggle.
  static const captionLines = 4;

  /// The title, author and tag lines exactly as the block lays them out
  /// for [entity] under [context], for [FeedTextWarmup]: the text a
  /// detail page shapes in the frame that builds it.
  static List<WarmText> warmTexts(BuildContext context, IllustEntity entity) =>
      illustDetailWarmTexts(context, entity);

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
            padding: EdgeInsets.only(
              top: showAuthor ? FuncSpacing.sm : FuncSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Official client order: the work title leads the meta block,
                // wraps without a line cap, and stays selectable — a one-line
                // AppBar title could only ellipsise. Without a caption the
                // title carries the translate button.
                entity.caption.isEmpty
                    ? Padding(
                        padding: _buttonRowMargin,
                        child: _TranslatableTitle(title: entity.title),
                      )
                    : _inMargin(_Title(title: entity.title)),
              ],
            ),
          ),
        ),
        if (showAuthor)
          _KeptPart(
            child: Padding(
              padding: _margin.copyWith(top: FuncSpacing.sm),
              child: DetailAuthorCard(entity: entity),
            ),
          ),
        _KeptPart(
          child: Padding(
            padding: _margin.copyWith(
              top: showAuthor ? FuncSpacing.md : FuncSpacing.sm,
            ),
            child: DetailMarksAndStats(entity: entity),
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
class DetailAuthorCard extends ConsumerWidget {
  const DetailAuthorCard({super.key, required this.entity});

  final IllustEntity entity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ownUserId = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent?.userId,
      ),
    );
    final author = entity.user;
    // The author is an object of its own on the page: its card rests on a
    // faint lift (THEME-20).
    final colors = Theme.of(context).colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: FuncShape.card,
          color: tokens.surface,
          border: Border.all(color: tokens.brandHairline),
        ),
        child: MiddleClickRegion(
          onMiddleClick: () =>
              DesktopWorkspaceTabsScope.maybeOf(
                context,
                listen: false,
              )?.openTargetInBackground(
                UserTabTarget(userId: author.id, name: author.name),
              ),
          child: PersonCard(
            key: const Key('illust-author-row'),
            onTap: () => openUser(context, author.id),
            tapHint: context.l10n.openAuthorProfile,
            trailing: author.id == ownUserId
                ? null
                // Capped at half the card so a long localized label leaves
                // the name a lane; the button scales its label down past it.
                : ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth / 2,
                    ),
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
              avatarRingColor: colors.primary.withValues(alpha: 0.45),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tags, each searching on a tap or, in the block mode, muting.
class _TagsSection extends ConsumerStatefulWidget {
  const _TagsSection({
    required this.entity,
    required this.blockMode,
    required this.onToggleBlockMode,
  });

  final IllustEntity entity;
  final bool blockMode;
  final VoidCallback onToggleBlockMode;

  @override
  ConsumerState<_TagsSection> createState() => _TagsSectionState();
}

class _TagsSectionState extends ConsumerState<_TagsSection> {
  final _chipKeys = <int, GlobalKey>{};

  GlobalKey _chipKey(int index) => _chipKeys.putIfAbsent(index, GlobalKey.new);

  @override
  Widget build(BuildContext context) {
    final entity = widget.entity;
    final blockMode = widget.blockMode;
    // Tag chips now block through the MuteStore: tag mutes sync with the
    // official /v1/mute list instead of the legacy local-only pref.
    final mutedTags = ref.watch(effectiveMutesProvider.select((s) => s.tags));
    final muteStore = ref.read(muteStoreProvider.notifier);
    VoidCallback? openTagInNewTab(IllustTag tag) {
      final tabs = DesktopWorkspaceTabsScope.maybeOf(context, listen: false);
      if (tabs == null) return null;
      return () => tabs.openTargetInBackground(
        SearchTabTarget(
          IllustSearchQuery(
            keyword: tag.name,
            filters: ref.read(searchIllustFiltersProvider),
          ),
        ),
      );
    }

    // The same entries as the long-press panel, beside the chip/pointer on a
    // PC (R11).
    void showTagActions(
      BuildContext anchorContext,
      IllustTag tag, {
      Offset? position,
    }) {
      final muted = mutedTags.contains(tag.name);
      unawaited(
        showTagActionsSheet(
          anchorContext,
          tag: tag.name,
          muted: muted,
          position: position,
          onSearch: () => openTagSearch(context, tag.name),
          onOpenInNewTab: openTagInNewTab(tag),
          onToggleMute: () => unawaited(
            toggleTagMute(context, muteStore, tag.name, muted: muted),
          ),
          onMuteMode: widget.onToggleBlockMode,
        ),
      );
    }

    VoidCallback tapFor(IllustTag tag) => () {
      if (blockMode) {
        unawaited(
          toggleTagMute(
            context,
            muteStore,
            tag.name,
            muted: mutedTags.contains(tag.name),
            confirmMute: false,
          ),
        );
      } else {
        unawaited(openTagSearch(context, tag.name));
      }
    };

    final isPc = FormFactor.of(context) == FormFactor.pc;
    return _Section(
      heading: blockMode
          ? context.l10n.tagActionMuteMode
          : context.l10n.detailSectionTags,
      action: blockMode
          ? TextButton(
              onPressed: widget.onToggleBlockMode,
              child: Text(context.l10n.tagMuteModeDone),
            )
          : null,
      child: isPc
          ? Wrap(
              children: [
                for (var i = 0; i < entity.tags.length; i++)
                  _DesktopAnchoredTagChip(
                    key: ValueKey('tag-anchor-$i-${entity.tags[i].name}'),
                    tag: entity.tags[i],
                    blockMode: blockMode,
                    blocked: mutedTags.contains(entity.tags[i].name),
                    onTap: tapFor(entity.tags[i]),
                    onMiddleClick: blockMode
                        ? null
                        : openTagInNewTab(entity.tags[i]),
                    onShowActions: (anchorContext, {position}) =>
                        showTagActions(
                          anchorContext,
                          entity.tags[i],
                          position: position,
                        ),
                  ),
              ],
            )
          : TagChips(
              children: [
                for (var i = 0; i < entity.tags.length; i++)
                  TagChip(
                    key: _chipKey(i),
                    label: entity.tags[i].name,
                    translated: entity.tags[i].translatedName,
                    blockMode: blockMode,
                    blocked: mutedTags.contains(entity.tags[i].name),
                    onTap: tapFor(entity.tags[i]),
                    onMiddleClick: blockMode
                        ? null
                        : openTagInNewTab(entity.tags[i]),
                    // Long-press opens the direct action menu (search /
                    // copy / mute / batch-mute entry) instead of silently
                    // flipping the block mode.
                    onLongPress: () => showTagActions(
                      _chipKey(i).currentContext ?? context,
                      entity.tags[i],
                    ),
                    onSecondaryTapAt: (position) => showTagActions(
                      _chipKey(i).currentContext ?? context,
                      entity.tags[i],
                      position: position,
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Anchors tag action popovers on desktop (`FormFactor.pc`) directly to the
/// clicked [TagChip] rather than falling back to a window-centered modal over
/// the artwork stage when triggered via long-press.
class _DesktopAnchoredTagChip extends StatefulWidget {
  const _DesktopAnchoredTagChip({
    super.key,
    required this.tag,
    required this.blockMode,
    required this.blocked,
    required this.onTap,
    this.onMiddleClick,
    required this.onShowActions,
  });

  final IllustTag tag;
  final bool blockMode;
  final bool blocked;
  final VoidCallback onTap;
  final VoidCallback? onMiddleClick;
  final void Function(BuildContext anchorContext, {Offset? position})
  onShowActions;

  @override
  State<_DesktopAnchoredTagChip> createState() =>
      _DesktopAnchoredTagChipState();
}

class _DesktopAnchoredTagChipState extends State<_DesktopAnchoredTagChip> {
  final _anchorKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: InputModalityScope(
                initialModality: InputModality.pointer,
                child: SizedBox.expand(key: _anchorKey),
              ),
            ),
          ),
        ),
        TagChip(
          label: widget.tag.name,
          translated: widget.tag.translatedName,
          blockMode: widget.blockMode,
          blocked: widget.blocked,
          onTap: widget.onTap,
          onMiddleClick: widget.onMiddleClick,
          onLongPress: () =>
              widget.onShowActions(_anchorKey.currentContext ?? context),
          onSecondaryTapAt: (position) => widget.onShowActions(
            _anchorKey.currentContext ?? context,
            position: position,
          ),
        ),
      ],
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
/// bookmarks and the full posting time.
class DetailMarksAndStats extends StatelessWidget {
  const DetailMarksAndStats({super.key, required this.entity});

  final IllustEntity entity;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final style = MetaFact.styleOf(context);
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
      child: Semantics(
        label: date == null
            ? l10n.detailMetaCountsSemantics(views, bookmarks)
            : l10n.detailStatsSemantics(views, bookmarks, date),
        child: ExcludeSemantics(
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
              MetaFact(icon: AppIcons.eye, text: views, style: style),
              MetaFact(icon: AppIcons.heart, text: bookmarks, style: style),
              if (date != null) Text(date, style: style),
            ],
          ),
        ),
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
    final style = MetaFact.styleOf(context);
    Widget boxed(Widget fact) => Padding(padding: inset, child: fact);
    return Wrap(
      key: const Key('illust-detail-facts'),
      // With the boxes, 12dp between two facts' text.
      spacing: FuncSpacing.md - inset.horizontal,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        boxed(
          MetaFact(
            icon: AppIcons.dimensions,
            text: '${entity.width}×${entity.height}',
            style: style,
          ),
        ),
        if (entity.pageCount > 1)
          boxed(
            MetaFact(
              icon: AppIcons.series,
              text: context.l10n.detailPageCount(entity.pageCount),
              style: style,
            ),
          ),
        if (entity.tools.isNotEmpty)
          Semantics(
            label: context.l10n.detailTools,
            child: boxed(
              MetaFact(
                icon: AppIcons.brush,
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
              Icon(AppIcons.tag, size: MetaFact.glyph, color: style.color),
              const SizedBox(width: FuncSpacing.xxs),
              Text('$id', style: style),
              const SizedBox(width: FuncSpacing.xs),
              Icon(AppIcons.copy, size: MetaFact.glyph, color: style.color),
            ],
          ),
        ),
      ),
    );
  }
}

/// The secondary metadata tier: the theme's small body text, tabular.
/// The work title: large, wrapping without a line cap, selectable.
class _Title extends StatelessWidget {
  const _Title({required this.title});

  final String title;

  static TextStyle _style(BuildContext context) =>
      FuncSemanticTokens.of(context).workTitle;

  @override
  Widget build(BuildContext context) => Text(title, style: _style(context));
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
