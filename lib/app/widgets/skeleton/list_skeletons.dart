import 'package:material_ui/material_ui.dart';

import '../../theme/func_semantic_tokens.dart';
import 'func_skeleton.dart';

/// First-load placeholders for card lists (R3). Each row repeats the card
/// margin, padding and leading size of the row it stands in for, so the
/// first real row lands where its skeleton was.
///
/// The novel rows mirror `NovelEntry.regular` (68×88 cover, title, author,
/// length); the user rows mirror the search user tile (52dp avatar, name,
/// account, compact follow button).
class NovelListSkeleton extends StatelessWidget {
  const NovelListSkeleton({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => FuncSkeleton(
    label: label,
    child: _SkeletonCardList(
      rowExtent: _novelRowExtent,
      row: (context) => const _NovelRowBones(),
    ),
  );
}

class UserListSkeleton extends StatelessWidget {
  const UserListSkeleton({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => FuncSkeleton(
    label: label,
    child: _SkeletonCardList(
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

/// Novel row height: cover plus the row padding plus the card margin.
const _novelRowExtent =
    _novelCoverHeight + 2 * FuncSpacing.md + 2 * FuncSpacing.sm;

/// User row height: the two-line ListTile plus the card margin.
const _userTileHeight = 72.0;
const _userRowExtent = _userTileHeight + 2 * FuncSpacing.sm;

const _avatarDiameter = 52.0;
const _followButtonWidth = 96.0;
const _followButtonHeight = 36.0;

/// Rows of card skeletons filling the available height; an unbounded height
/// gets three rows.
class _SkeletonCardList extends StatelessWidget {
  const _SkeletonCardList({required this.rowExtent, required this.row});

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
                Card(margin: _cardMargin, child: row(context)),
            ],
          ),
        ),
      );
    },
  );
}

class _NovelRowBones extends StatelessWidget {
  const _NovelRowBones();

  @override
  Widget build(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    final titleStyle = DefaultTextStyle.of(
      context,
    ).style.copyWith(fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.all(FuncSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SkeletonBone(
            width: _novelCoverWidth,
            height: _novelCoverHeight,
          ),
          const SizedBox(width: FuncSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBone.text(style: titleStyle),
                const SizedBox(height: FuncSpacing.xs),
                FractionallySizedBox(
                  widthFactor: 0.4,
                  child: SkeletonBone.text(style: tokens.caption),
                ),
                const SizedBox(height: FuncSpacing.xs),
                FractionallySizedBox(
                  widthFactor: 0.25,
                  child: SkeletonBone.text(style: tokens.caption),
                ),
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
