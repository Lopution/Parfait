import 'package:material_ui/material_ui.dart';

import '../../core/novel/novel_entity.dart';
import '../../l10n/context.dart';
import '../format/app_format.dart';
import '../navigation/routes.dart';
import '../pixiv_image.dart';
import '../theme/func_semantic_tokens.dart';
import 'entity_row.dart';

/// The single novel list-entry contract — replaces the parallel
/// `NovelCard`/`NovelRow` pair (roadmap §5.2, R1). Density follows the
/// list's role rather than historical accident:
///
/// - [NovelEntry.compact]: inline secondary feeds (the recommended mixed
///   feed) — 56×72 cover, r4.
/// - [NovelEntry.regular]: lists where novels are the primary content
///   (search results, new works, profile feed) — 68×88 cover, r6.
/// - [NovelEntry.ranking]: ranked lists — compact density plus the rank
///   leading the title.
///
/// Every variant is a full-bleed list row sharing the same identity: title,
/// author, series and word count, a tag footnote, the bookmark count on the
/// cover, the work-id key and the [openNovel] primary action — pages never
/// restyle a novel row.
class NovelEntry extends StatelessWidget {
  NovelEntry._({
    Key? key,
    required this.entity,
    required double coverWidth,
    required double coverHeight,
    required double coverRadius,
    this.rank,
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
         progress: progress,
         trailing: trailing,
         onTap: onTap,
         onLongPress: onLongPress,
         selected: selected,
         semanticLabel: semanticLabel,
       );

  /// Ranked list density — compact cover plus the rank leading the title
  /// line.
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
         coverWidth: 56,
         coverHeight: 72,
         coverRadius: 4,
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

  /// Inset of the cover's bookmark badge — tighter than a feed card's 7dp,
  /// the cover is a fraction of its size.
  static const double _badgeInset = 4;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bookmarks = entity.totalBookmarks > 0
        ? AppFormat.count(context, entity.totalBookmarks)
        : null;
    final words =
        '${AppFormat.count(context, entity.textLength)} '
        '${l10n.novelWords}';
    final series = entity.seriesTitle;
    final identity = [
      if (rank != null) l10n.rankLabel(rank!),
      entity.title,
      entity.user.name,
      if (bookmarks != null) l10n.novelEntryBookmarks(bookmarks),
    ].join(', ');
    // Full-bleed row with list-row ink (HCI 11): no card chrome, so a
    // column of novels reads as one list rather than a stack of tiles.
    return EntityRow(
      padding: const EdgeInsets.symmetric(
        horizontal: FuncSpacing.lg,
        vertical: FuncSpacing.md,
      ),
      leading: _cover(context, bookmarks),
      title: entity.title,
      titleLeading: rank == null ? null : EntityRankLabel(rank!),
      subtitle: entity.user.name,
      meta: series == null || series.isEmpty ? words : '$series · $words',
      footnote: entity.tags.isEmpty
          ? null
          : entity.tags.take(_maxTags).map((tag) => '#${tag.name}').join(' '),
      progress: progress,
      trailing: trailing,
      onTap: onTap ?? () => openNovel(context, entity.id),
      onLongPress: onLongPress,
      selected: selected,
      semanticLabel: semanticLabel ?? identity,
    );
  }

  /// The cover with its bookmark count laid over the bottom edge, in the
  /// same scrim badge the illust cards use.
  Widget _cover(BuildContext context, String? bookmarks) {
    final colorScheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(_coverRadius),
      child: SizedBox(
        width: _coverWidth,
        height: _coverHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The placeholder takes the same clip — the old NovelRow let it
            // fall outside ClipRRect and painted square corners.
            if (entity.coverImageUrl == null)
              ColoredBox(
                color: colorScheme.surfaceContainer,
                child: const Icon(Icons.menu_book_outlined),
              )
            else
              PixivImage.feed(entity.coverImageUrl!, layoutWidth: _coverWidth),
            if (bookmarks != null)
              Positioned(
                left: _badgeInset,
                bottom: _badgeInset,
                child: EntityBadge(icon: Icons.favorite, label: bookmarks),
              ),
          ],
        ),
      ),
    );
  }
}
