import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/mute/mute_predicate.dart';
import '../../core/mute/mute_store.dart';
import '../../core/novel/novel_entity.dart';
import '../../l10n/context.dart';
import '../format/app_format.dart';
import '../navigation/route_facade.dart';
import '../pixiv_image.dart';
import '../theme/func_semantic_tokens.dart';
import 'entity_row.dart';
import 'feed/feed_text_warmup.dart';
import 'feed/muted_cover.dart';
import '../icons/app_icons.dart';

/// The single novel list-entry contract — replaces the parallel
/// `NovelCard`/`NovelRow` pair (roadmap §5.2, R1). Density follows the
/// list's role rather than historical accident:
///
/// - [NovelEntry.compact]: inline secondary feeds (the recommended mixed
///   feed) — 56×72 cover, r4.
/// - [NovelEntry.regular]: lists where novels are the primary content
///   (search results, new works, profile feed) — 68×88 cover, r6.
/// - [NovelEntry.ranking]: ranked lists — regular density (the novels are
///   the page) plus the rank leading the title.
///
/// Every variant is a full-bleed list row sharing the same identity: title,
/// author, series and word count, a tag footnote, the bookmark count on the
/// cover, the work-id key and the [openNovel] primary action — pages never
/// restyle a novel row.
///
/// A muted novel (its author or a tag) blurs its cover and shows the reason
/// in place of the title, series and tags, until a tap reveals it — as
/// [IllustCard] does. A feed in hide mode never builds the row.
class NovelEntry extends ConsumerWidget {
  NovelEntry._({
    Key? key,
    required this.entity,
    required double coverWidth,
    required double coverHeight,
    required double coverRadius,
    this.rank,
    this.overline,
    this.showSeries = true,
    this.progress,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.semanticLabel,
  }) : _coverWidth = coverWidth,
       _coverHeight = coverHeight,
       _coverRadius = coverRadius,
       // Work-id default key — same slot-hand-off contract as IllustCard:
       // the element follows the work across feed refreshes.
       super(key: key ?? ValueKey('novel-${entity.id}'));

  /// Inline feed density (recommended mixed feed): 56×72, r4.
  NovelEntry.compact({
    Key? key,
    required NovelEntity entity,
    double? progress,
    Widget? trailing,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    bool selected = false,
    String? semanticLabel,
  }) : this._(
         key: key,
         entity: entity,
         coverWidth: 56,
         coverHeight: 72,
         coverRadius: 4,
         progress: progress,
         trailing: trailing,
         onTap: onTap,
         onLongPress: onLongPress,
         selected: selected,
         semanticLabel: semanticLabel,
       );

  /// Primary-list density (search / new / profile): 68×88, r6.
  NovelEntry.regular({
    Key? key,
    required NovelEntity entity,
    String? overline,
    bool showSeries = true,
    double? progress,
    Widget? trailing,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    bool selected = false,
    String? semanticLabel,
  }) : this._(
         key: key,
         entity: entity,
         coverWidth: 68,
         coverHeight: 88,
         coverRadius: 6,
         overline: overline,
         showSeries: showSeries,
         progress: progress,
         trailing: trailing,
         onTap: onTap,
         onLongPress: onLongPress,
         selected: selected,
         semanticLabel: semanticLabel,
       );

  /// Ranked list density — the regular cover plus the rank leading the
  /// title line.
  NovelEntry.ranking({
    Key? key,
    required NovelEntity entity,
    required int rank,
    double? progress,
    Widget? trailing,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    bool selected = false,
    String? semanticLabel,
  }) : this._(
         key: key,
         entity: entity,
         coverWidth: 68,
         coverHeight: 88,
         coverRadius: 6,
         rank: rank,
         progress: progress,
         trailing: trailing,
         onTap: onTap,
         onLongPress: onLongPress,
         selected: selected,
         semanticLabel: semanticLabel,
       );

  final NovelEntity entity;
  final double _coverWidth;
  final double _coverHeight;
  final double _coverRadius;

  /// Ranking position — set only by [NovelEntry.ranking].
  final int? rank;

  /// Short label above the title, read first — where the account's
  /// bookmark is, in the bookmark list.
  final String? overline;

  /// Whether the length line names the novel's series; off where the list
  /// is the series.
  final bool showSeries;

  /// Reading-progress slot (W5 semantics): `null` renders nothing, `0.0`
  /// renders an empty bar — a real "started from the top" record.
  final double? progress;

  /// Trailing action slot — e.g. `BookmarkSwitchButton(isNovel: true)`.
  /// Defaults to null: feed surfaces carry no secondary action.
  final Widget? trailing;

  /// Primary action override; defaults to [openNovel] for [entity].
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Management-mode selected state — forwarded to the row.
  final bool selected;

  /// Accessibility label; defaults to `'$title, $author'`.
  final String? semanticLabel;

  /// Tags shown on the footnote line; the rest would be cut anyway.
  static const _maxTags = 4;

  /// The row's text lines for [entity], as every variant lays them out
  /// under [context], for [FeedTextWarmup]. The rank is digits in the
  /// primary font and left out.
  static List<WarmText> warmTexts(BuildContext context, NovelEntity entity) {
    final bookmarks = entity.totalBookmarks > 0
        ? AppFormat.count(context, entity.totalBookmarks)
        : null;
    return EntityRow.warmTexts(
      context,
      title: entity.title,
      subtitle: entity.user.name,
      meta: _meta(context, entity, bookmarks: bookmarks),
      footnote: _footnote(entity),
    );
  }

  /// Content marks (R-18 / R-18G / AI), series (when any and [showSeries]),
  /// word count, and bookmark count. Keeping bookmarks and marks in the text
  /// column avoids clipping on 56/68dp narrow covers (LAYOUT-01, PAGING-10).
  static String _meta(
    BuildContext context,
    NovelEntity entity, {
    bool showSeries = true,
    String? bookmarks,
  }) {
    final l10n = context.l10n;
    final words =
        '${AppFormat.count(context, entity.textLength)} ${l10n.novelWords}';
    final series = showSeries ? entity.seriesTitle : null;
    return [
      if (entity.isR18) 'R-18',
      if (entity.isR18G) 'R-18G',
      if (entity.isAi) l10n.badgeAi,
      if (series != null && series.isNotEmpty) series,
      words,
      if (bookmarks != null) l10n.novelEntryBookmarks(bookmarks),
    ].join(' · ');
  }

  static String? _footnote(NovelEntity entity) => entity.tags.isEmpty
      ? null
      : entity.tags.take(_maxTags).map((tag) => '#${tag.name}').join(' ');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final hit = ref.watch(
      muteStoreProvider.select((mutes) => novelMuteHitFor(entity, mutes)),
    );
    final revealed = ref.watch(
      revealedMutedNovelIdsProvider.select((ids) => ids.contains(entity.id)),
    );
    final muted = hit != null && !revealed;
    final title = muted
        ? l10n.labelValue(l10n.mutedContent, hit.label)
        : entity.title;
    final bookmarks = !muted && entity.totalBookmarks > 0
        ? AppFormat.count(context, entity.totalBookmarks)
        : null;
    final identity = [
      ?overline,
      if (rank != null) l10n.rankLabel(rank!),
      title,
      entity.user.name,
      if (!muted && entity.isR18) 'R-18',
      if (!muted && entity.isR18G) 'R-18G',
      if (!muted && entity.isAi) l10n.badgeAi,
      if (bookmarks != null) l10n.novelEntryBookmarks(bookmarks),
    ].join(', ');
    // Full-bleed row with list-row ink (HCI 11): no card chrome, so a
    // column of novels reads as one list rather than a stack of tiles.
    return EntityRow(
      padding: const EdgeInsets.symmetric(
        horizontal: FuncSpacing.lg,
        vertical: FuncSpacing.md,
      ),
      leading: _cover(context, muted: muted),
      overline: overline,
      title: title,
      titleLeading: rank == null ? null : EntityRankLabel(rank!),
      subtitle: entity.user.name,
      meta: muted
          ? null
          : _meta(
              context,
              entity,
              showSeries: showSeries,
              bookmarks: bookmarks,
            ),
      footnote: muted ? null : _footnote(entity),
      progress: progress,
      trailing: trailing,
      onTap: muted
          ? () => ref
                .read(revealedMutedNovelIdsProvider.notifier)
                .reveal(entity.id)
          : onTap ?? () => openNovel(context, entity.id),
      onLongPress: onLongPress,
      selected: selected,
      semanticLabel: muted ? identity : semanticLabel ?? identity,
    );
  }

  /// Unoccluded cover thumbnail — bookmarks and R-18/AI marks live in `_meta`
  /// so compact 56×72 covers never clip overlays.
  Widget _cover(BuildContext context, {required bool muted}) {
    final colorScheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(_coverRadius),
      child: SizedBox(
        width: _coverWidth,
        height: _coverHeight,
        child: entity.coverImageUrl == null
            ? ColoredBox(
                color: colorScheme.surfaceContainer,
                child: const Icon(AppIcons.novel),
              )
            : PixivImage.feed(
                entity.coverImageUrl!,
                layoutWidth: _coverWidth,
                blur: muted ? MutedCover.blurSigma : null,
              ),
      ),
    );
  }
}
