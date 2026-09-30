import 'package:material_ui/material_ui.dart';

import '../../../../app/layout/app_breakpoints.dart';
import '../../../../app/layout/two_pane.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/skeleton/func_skeleton.dart';
import '../../../../l10n/context.dart';

/// First-load placeholder for the detail page when the IllustStore holds no
/// snapshot for the work — a cold open paints the layout's bones instead of
/// a bare spinner. When a snapshot exists the page renders it directly (the
/// Hero destination must exist on the first frame), so this widget only ever
/// covers the truly-empty loading branch.
class IllustDetailSkeleton extends StatelessWidget {
  const IllustDetailSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = AppBreakpoints.useTwoPaneDetail(
      MediaQuery.sizeOf(context).width,
    );
    return FuncSkeleton(
      label: context.l10n.contentLoading,
      // The artwork's aspect ratio is unknown until the entity arrives —
      // a full-width square is the middle ground, matching how the pager's
      // first frame sizes unknown media.
      child: wide
          ? const TwoPane(
              primary: _ImageBone(),
              secondary: SingleChildScrollView(child: _MetaBones()),
            )
          : const SingleChildScrollView(
              physics: NeverScrollableScrollPhysics(),
              child: Column(
                children: [
                  AspectRatio(aspectRatio: 1, child: _ImageBone()),
                  _MetaBones(),
                ],
              ),
            ),
    );
  }
}

/// The artwork placeholder: full-bleed (no corner radius) so it reads as
/// the image area rather than a card.
class _ImageBone extends StatelessWidget {
  const _ImageBone();

  @override
  Widget build(BuildContext context) {
    return const SkeletonBone(
      width: double.infinity,
      height: double.infinity,
      borderRadius: BorderRadius.zero,
    );
  }
}

/// The info block's bones in [InfoBlock]'s order: title → author row →
/// stats → date → tag pills, inside the same `FuncSpacing.xl` padding.
class _MetaBones extends StatelessWidget {
  const _MetaBones();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(FuncSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FractionallySizedBox(
            widthFactor: 0.7,
            child: SkeletonBone.text(style: textTheme.titleLarge),
          ),
          const SizedBox(height: FuncSpacing.md),
          Row(
            children: [
              const SkeletonBone.circle(diameter: 40),
              const SizedBox(width: FuncSpacing.md),
              Expanded(child: SkeletonBone.text(style: textTheme.titleMedium)),
            ],
          ),
          const SizedBox(height: FuncSpacing.lg),
          FractionallySizedBox(
            widthFactor: 0.5,
            child: SkeletonBone.text(style: textTheme.bodySmall),
          ),
          const SizedBox(height: FuncSpacing.lg),
          FractionallySizedBox(
            widthFactor: 0.4,
            child: SkeletonBone.text(style: textTheme.bodySmall),
          ),
          const SizedBox(height: FuncSpacing.lg),
          const Row(
            children: [
              SkeletonBone(width: 56, height: 30, borderRadius: FuncShape.pill),
              SizedBox(width: FuncSpacing.sm),
              SkeletonBone(width: 72, height: 30, borderRadius: FuncShape.pill),
              SizedBox(width: FuncSpacing.sm),
              SkeletonBone(width: 48, height: 30, borderRadius: FuncShape.pill),
            ],
          ),
        ],
      ),
    );
  }
}
