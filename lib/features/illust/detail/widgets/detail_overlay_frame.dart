import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../../app/layout/app_breakpoints.dart';
import '../../../../app/navigation/home_shell_metrics.dart';
import '../../../../app/theme/func_semantic_tokens.dart';

/// Frames wide flat detail routes (`>= 960x600`) inside a scrimmed modal card
/// over the live feed while keeping [child]'s state anchored across resizes
/// via a persistent [GlobalKey].
class DetailOverlayFrame extends StatefulWidget {
  const DetailOverlayFrame({super.key, required this.child});

  final Widget child;

  @override
  State<DetailOverlayFrame> createState() => _DetailOverlayFrameState();
}

class _DetailOverlayFrameState extends State<DetailOverlayFrame> {
  final _childKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final content = KeyedSubtree(key: _childKey, child: widget.child);
    final outerSize = HomeShellChrome.contentSizeOf(context);
    final canPop = Navigator.maybeOf(context)?.canPop() ?? false;
    final bounded =
        canPop && AppBreakpoints.useBoundedDetailOverlayOf(context, outerSize);
    if (!bounded) return content;

    final colors = Theme.of(context).colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final outerChrome = HomeShellChrome.maybeOf(context);
    final outerMedia = MediaQuery.of(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          key: const ValueKey('detail-overlay-scrim'),
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(Navigator.maybePop(context)),
          child: ColoredBox(color: colors.scrim.withValues(alpha: 0.52)),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FuncSpacing.xl,
              vertical: FuncSpacing.lg,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1480),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final cardSize = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    final framedChild = MediaQuery(
                      data: outerMedia
                          .copyWith(size: cardSize)
                          .removePadding(
                            removeTop: true,
                            removeBottom: true,
                            removeLeft: true,
                            removeRight: true,
                          ),
                      child: outerChrome == null
                          ? content
                          : HomeShellChrome(
                              bottomBarExtent: 0,
                              railExtent: 0,
                              bottomBarVisibleExtent:
                                  outerChrome.bottomBarVisibleExtent,
                              bottomBarVisibility:
                                  outerChrome.bottomBarVisibility,
                              onBranchRootScroll:
                                  outerChrome.onBranchRootScroll,
                              child: content,
                            ),
                    );
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: FuncShape.dialog,
                        border: Border.all(color: colors.outlineVariant),
                        boxShadow: tokens.layerLift,
                      ),
                      child: ClipRRect(
                        borderRadius: FuncShape.dialog,
                        child: framedChild,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
