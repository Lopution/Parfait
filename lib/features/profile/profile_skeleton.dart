import 'package:material_ui/material_ui.dart';

import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/skeleton/func_skeleton.dart';
import '../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../l10n/context.dart';
import 'profile_header_delegate.dart';
import 'profile_illust_feed.dart';

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
                      // The avatar's lower half.
                      const SizedBox(height: avatarRadius + FuncSpacing.sm),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FuncSpacing.lg,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  FractionallySizedBox(
                                    key: const ValueKey(
                                      'profile-skeleton-name',
                                    ),
                                    widthFactor: 0.45,
                                    child: SkeletonBone.text(
                                      style: textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  FractionallySizedBox(
                                    widthFactor: 0.3,
                                    child: SkeletonBone.text(
                                      style: textTheme.bodyMedium,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // The share button's slot sets the row's
                            // minimum height, as in the real header.
                            const SizedBox.square(
                              dimension: kMinInteractiveDimension,
                            ),
                          ],
                        ),
                      ),
                      // The counters: figure-over-label blocks, at least
                      // 48dp tall, as in the real header.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          FuncSpacing.lg,
                          FuncSpacing.xs,
                          FuncSpacing.lg,
                          0,
                        ),
                        child: Row(
                          children: [
                            for (final width in const [48.0, 56.0]) ...[
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: kMinInteractiveDimension,
                                ),
                                child: Padding(
                                  padding: const EdgeInsetsDirectional.only(
                                    top: FuncSpacing.xxs,
                                    bottom: FuncSpacing.xxs,
                                    end: FuncSpacing.lg,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SkeletonBone.text(
                                        width: width * 0.6,
                                        style: textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      SkeletonBone.text(
                                        width: width,
                                        style: textTheme.labelMedium,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: FuncSpacing.sm),
                      // The tab strip's slot: the band stays empty — fake tab
                      // captions would read as content, not placeholder.
                      const SizedBox(
                        key: ValueKey('profile-skeleton-tabs'),
                        height: kToolbarHeight,
                      ),
                      // Unbounded here, so the grid paints three cards per
                      // column; the viewport clips whatever does not fit.
                      IllustGridSkeleton(
                        label: context.l10n.profileLoading,
                        padding: gridPadding,
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
