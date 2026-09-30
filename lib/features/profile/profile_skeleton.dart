import 'package:material_ui/material_ui.dart';

import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/skeleton/func_skeleton.dart';
import '../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../l10n/context.dart';
import 'profile_header_delegate.dart';
import 'profile_statistics.dart';

/// First-load placeholder for the user page: the header's no-cover layout —
/// banner band, avatar straddling the banner's bottom edge, identity bones,
/// the tab slot, then the works grid — instead of a bare spinner.
///
/// The bones follow `_ProfileExpandedIdentity`'s vertical rhythm so the
/// name, stats and grid do not jump when the real header replaces them.
///
/// The banner is structure, not a bone: it keeps the real header's
/// `surfaceContainerHigh` and sits beneath [FuncSkeleton] so the shimmer
/// never sweeps it. The [BackButton] is real too — loading must never trap
/// the route — so it lives outside the skeleton's excluded semantics.
class ProfileSkeleton extends StatelessWidget {
  const ProfileSkeleton({super.key});

  /// Statistic cells per row on a phone: six stats as 3×2, the grid's
  /// usual choice at that width.
  static const _statColumns = 3;
  static const _statRows = 2;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.viewPaddingOf(context).top;
    const avatarRadius = ReplicaProfileHeaderGeometry.avatarRadius;
    final bannerHeight =
        topInset +
        kToolbarHeight +
        ReplicaProfileHeaderGeometry.bannerBelowToolbar;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final canPop = Navigator.maybeOf(context)?.canPop() ?? false;

    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: bannerHeight,
          child: ColoredBox(color: colorScheme.surfaceContainerHigh),
        ),
        Positioned.fill(
          child: FuncSkeleton(
            label: context.l10n.profileLoading,
            // Clipped, not scrolled: a short landscape viewport cuts the
            // bones off instead of overflowing.
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: bannerHeight),
                      // The action row's slot right of the avatar's lower
                      // half, at the header's minimum height.
                      const SizedBox(height: avatarRadius + FuncSpacing.sm),
                      const SizedBox(height: FuncSpacing.sm),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FuncSpacing.lg,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FractionallySizedBox(
                              key: const ValueKey('profile-skeleton-name'),
                              widthFactor: 0.45,
                              child: SkeletonBone.text(
                                style: textTheme.titleLarge,
                              ),
                            ),
                            const SizedBox(height: 2),
                            FractionallySizedBox(
                              widthFactor: 0.3,
                              child: SkeletonBone.text(
                                style: textTheme.bodyMedium,
                              ),
                            ),
                            const SizedBox(height: FuncSpacing.md),
                            for (var row = 0; row < _statRows; row++) ...[
                              if (row > 0)
                                const SizedBox(
                                  height: ProfileStatisticsGrid.gap,
                                ),
                              _StatBoneRow(
                                columns: _statColumns,
                                valueStyle: textTheme.titleMedium,
                                labelStyle: textTheme.labelMedium,
                              ),
                            ],
                            const SizedBox(height: FuncSpacing.md),
                          ],
                        ),
                      ),
                      // The tab strip's slot: the band stays empty — fake tab
                      // captions would read as content, not placeholder.
                      const SizedBox(height: kToolbarHeight),
                      // Unbounded here, so the grid paints three cards per
                      // column; the viewport clips whatever does not fit.
                      IllustGridSkeleton(
                        label: context.l10n.profileLoading,
                        padding: const EdgeInsets.all(10),
                      ),
                    ],
                  ),
                  // Avatar centred on the banner's bottom edge, as in the
                  // real header.
                  Positioned(
                    left: FuncSpacing.lg,
                    top: bannerHeight - avatarRadius,
                    child: const SkeletonBone.circle(
                      key: ValueKey('profile-skeleton-avatar'),
                      diameter: avatarRadius * 2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (canPop)
          Positioned(top: topInset, left: 0, child: const BackButton()),
      ],
    );
  }
}

/// One row of the statistics grid's cells: value over label, centred, with
/// the cell's `FuncSpacing.xs` padding.
class _StatBoneRow extends StatelessWidget {
  const _StatBoneRow({
    required this.columns,
    required this.valueStyle,
    required this.labelStyle,
  });

  final int columns;
  final TextStyle? valueStyle;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var c = 0; c < columns; c++) ...[
          if (c > 0) const SizedBox(width: ProfileStatisticsGrid.gap),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(FuncSpacing.xs),
              child: Column(
                children: [
                  SkeletonBone.text(width: 32, style: valueStyle),
                  const SizedBox(height: FuncSpacing.xxs),
                  SkeletonBone.text(width: 48, style: labelStyle),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
