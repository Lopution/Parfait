import 'package:material_ui/material_ui.dart';

import '../../core/novel/novel_entity.dart';
import '../../l10n/context.dart';
import '../navigation/routes.dart';
import '../pixiv_image.dart';
import '../theme/func_tokens.dart';
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
///   badge.
///
/// Every variant shares the same identity line (title, author, word count
/// meta), the work-id key, the [openNovel] primary action, and the
/// `PressScale` + `Semantics` wrapper — pages never restyle a novel row.
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

  /// Ranked list density — compact cover plus a rank badge pinned to its
  /// top-left corner.
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

  /// Rank badge value — set only by [NovelEntry.ranking].
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: EntityRow(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(_coverRadius),
          child: SizedBox(
            width: _coverWidth,
            height: _coverHeight,
            // The placeholder takes the same clip — the old NovelRow let
            // it fall outside ClipRRect and painted square corners.
            child: entity.coverImageUrl == null
                ? ColoredBox(
                    color: colorScheme.surfaceContainer,
                    child: const Icon(Icons.menu_book_outlined),
                  )
                : PixivImage.feed(
                    entity.coverImageUrl!,
                    layoutWidth: _coverWidth,
                    placeholderColor: colorScheme.surfaceContainer,
                  ),
          ),
        ),
        badge: rank == null ? null : _RankBadge(rank!),
        title: entity.title,
        subtitle: entity.user.name,
        meta: '${entity.textLength} ${context.l10n.novelWords}',
        progress: progress,
        trailing: trailing,
        onTap: onTap ?? () => openNovel(context, entity.id),
        onLongPress: onLongPress,
        selected: selected,
        semanticLabel: semanticLabel,
      ),
    );
  }
}

/// Rank pill shared by the ranking variant — same container contract as
/// the illust card badges ([EntityBadge]) filled with the primary color.
class _RankBadge extends StatelessWidget {
  const _RankBadge(this.rank);

  final int rank;

  @override
  Widget build(BuildContext context) {
    return EntityBadge(
      color: Theme.of(context).colorScheme.primary,
      child: Text(
        '$rank',
        style: const TextStyle(
          color: FuncTokens.lightBackground,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
