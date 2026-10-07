import 'package:material_ui/material_ui.dart';

import '../../theme/func_semantic_tokens.dart';
import 'func_skeleton.dart';

/// First-load placeholders for lists (R3). Each row repeats the chrome,
/// padding and leading size of the row it stands in for, so the first real
/// row lands where its skeleton was.
///
/// The novel rows mirror the full-bleed `NovelEntry.regular` (68×88 cover,
/// title, author, length, tags); the user rows mirror the search user card
/// (52dp avatar, name, account, compact follow button).
class NovelListSkeleton extends StatelessWidget {
  const NovelListSkeleton({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => FuncSkeleton(
    label: label,
    child: _SkeletonList(
      carded: false,
      rowExtent: _novelRowExtent,
      row: (context) => const _CoverRowBones(
        coverWidth: _novelCoverWidth,
        coverHeight: _novelCoverHeight,
        padding: _novelRowPadding,
        overline: false,
        captionWidths: [0.4, 0.25, 0.55],
      ),
    ),
  );
}

/// Mirrors the episode rows of a manga series (72×96 cover, episode
/// number, title, date).
class EpisodeListSkeleton extends StatelessWidget {
  const EpisodeListSkeleton({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => FuncSkeleton(
    label: label,
    child: _SkeletonList(
      carded: false,
      rowExtent: episodeCoverSize.height + episodeRowPadding.vertical,
      row: (context) => _CoverRowBones(
        coverWidth: episodeCoverSize.width,
        coverHeight: episodeCoverSize.height,
        padding: episodeRowPadding,
        overline: true,
        captionWidths: const [0.3],
      ),
    ),
  );
}

/// Episode row cover and padding, shared with the series page's rows.
const episodeCoverSize = Size(72, 96);
const episodeRowPadding = EdgeInsets.symmetric(
  horizontal: FuncSpacing.lg,
  vertical: FuncSpacing.sm,
);

class UserListSkeleton extends StatelessWidget {
  const UserListSkeleton({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => FuncSkeleton(
    label: label,
    child: _SkeletonList(
      carded: true,
      rowExtent: _userRowExtent,
      row: (context) => const _UserRowBones(),
    ),
  );
}

/// The card margin every list row uses.
const _cardMargin = EdgeInsets.symmetric(
  horizontal: FuncSpacing.md,
  vertical: FuncSpacing.sm,
);

const _novelCoverWidth = 68.0;
const _novelCoverHeight = 88.0;

/// Novel row padding, as `NovelEntry` sets it.
const _novelRowPadding = EdgeInsets.symmetric(
  horizontal: FuncSpacing.lg,
  vertical: FuncSpacing.md,
);

/// Novel row height: the cover plus the row padding.
const _novelRowExtent = _novelCoverHeight + 2 * FuncSpacing.md;

/// User row height: the two-line ListTile plus the card margin.
const _userTileHeight = 72.0;
const _userRowExtent = _userTileHeight + 2 * FuncSpacing.sm;

const _avatarDiameter = 52.0;
const _followButtonWidth = 96.0;
const _followButtonHeight = 36.0;

/// Rows of skeletons filling the available height; an unbounded height gets
/// three rows.
class _SkeletonList extends StatelessWidget {
  const _SkeletonList({
    required this.carded,
    required this.rowExtent,
    required this.row,
  });

  /// Whether each row sits on a card, as the user rows do.
  final bool carded;
  final double rowExtent;
  final WidgetBuilder row;

  static const _unboundedRows = 3;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final rows = constraints.hasBoundedHeight
          ? (constraints.maxHeight / rowExtent).ceil()
          : _unboundedRows;
      return ClipRect(
        child: OverflowBox(
          alignment: Alignment.topCenter,
          maxHeight: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < rows; i++)
                if (carded)
                  Card(margin: _cardMargin, child: row(context))
                else
                  row(context),
            ],
          ),
        ),
      );
    },
  );
}

/// A cover with a column of text bones beside it, padded like the
/// full-bleed `EntityRow` it stands in for.
class _CoverRowBones extends StatelessWidget {
  const _CoverRowBones({
    required this.coverWidth,
    required this.coverHeight,
    required this.padding,
    required this.overline,
    required this.captionWidths,
  });

  final double coverWidth;
  final double coverHeight;
  final EdgeInsets padding;

  /// Whether a label sits above the title (the episode number).
  final bool overline;

  /// One caption bone per secondary line, as fractions of the text column.
  final List<double> captionWidths;

  /// Width of the overline bone, as a fraction of the text column.
  static const _overlineWidth = 0.2;

  @override
  Widget build(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    final titleStyle = DefaultTextStyle.of(
      context,
    ).style.copyWith(fontWeight: FontWeight.w600);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBone(width: coverWidth, height: coverHeight),
          const SizedBox(width: FuncSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (overline) ...[
                  FractionallySizedBox(
                    widthFactor: _overlineWidth,
                    child: SkeletonBone.text(
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  const SizedBox(height: FuncSpacing.xxs),
                ],
                SkeletonBone.text(style: titleStyle),
                for (final width in captionWidths) ...[
                  const SizedBox(height: FuncSpacing.xs),
                  FractionallySizedBox(
                    widthFactor: width,
                    child: SkeletonBone.text(style: tokens.caption),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UserRowBones extends StatelessWidget {
  const _UserRowBones();

  @override
  Widget build(BuildContext context) {
    // ListTile's own title and subtitle styles.
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      height: _userTileHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
        child: Row(
          children: [
            const SkeletonBone.circle(diameter: _avatarDiameter),
            const SizedBox(width: FuncSpacing.lg),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(
                    widthFactor: 0.5,
                    child: SkeletonBone.text(style: textTheme.bodyLarge),
                  ),
                  const SizedBox(height: FuncSpacing.xs),
                  FractionallySizedBox(
                    widthFactor: 0.7,
                    child: SkeletonBone.text(style: textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
            const SizedBox(width: FuncSpacing.lg),
            const SkeletonBone(
              width: _followButtonWidth,
              height: _followButtonHeight,
              borderRadius: FuncShape.pill,
            ),
          ],
        ),
      ),
    );
  }
}
