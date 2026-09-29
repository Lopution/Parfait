import 'package:material_ui/material_ui.dart';

import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/theme/func_tokens.dart';
import '../../../../l10n/context.dart';

/// Page position over the artwork ("N / M"), shared by the narrow scroll
/// body and the two-pane pager. Hidden for single-page works and until the
/// route's entry transition settles; never takes pointer input.
class DetailPageCounter extends StatefulWidget {
  const DetailPageCounter({super.key, required this.page, required this.count});

  /// Zero-based page shown as `page + 1`.
  final int page;
  final int count;

  @override
  State<DetailPageCounter> createState() => _DetailPageCounterState();
}

class _DetailPageCounterState extends State<DetailPageCounter> {
  /// The pill stays out of the entry flight so the Hero lands clean, then
  /// appears on the first settled frame. Once shown it stays — on pop it
  /// slides away with the page, not with a Hero.
  bool _routeTransitionComplete = true;
  Animation<double>? _routeAnimation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _routeAnimation)) return;

    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
    _routeAnimation = animation;
    if (animation == null) {
      _routeTransitionComplete = true;
      return;
    }
    // ModalRoute.animation is a proxy that reports `completed` for the
    // route's offstage first frame (hero measurement) and re-points to the
    // real entrance animation afterwards — the listener must be attached
    // unconditionally to catch that swap, which notifies a `forward`
    // status; a `home:` initial route reports completed and never notifies.
    _routeTransitionComplete = animation.status == AnimationStatus.completed;
    animation.addStatusListener(_handleRouteAnimationStatus);
  }

  void _handleRouteAnimationStatus(AnimationStatus status) {
    if (!mounted) return;
    switch (status) {
      case AnimationStatus.completed:
        if (!_routeTransitionComplete) {
          setState(() => _routeTransitionComplete = true);
        }
      case AnimationStatus.forward:
        // The entrance transition is running — keep the pill hidden.
        if (_routeTransitionComplete) {
          setState(() => _routeTransitionComplete = false);
        }
      // reverse/dismissed belong to the outgoing flight: leave the pill as
      // it is — it slides away with the page and never joins a Hero.
      case AnimationStatus.reverse || AnimationStatus.dismissed:
        break;
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The "multi-page only" check lives here so neither caller repeats it;
    // the pill also waits out the entry transition (Hero landing contract).
    if (widget.count < 2 || !_routeTransitionComplete) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    // Callers hand over the whole image area via Positioned.fill; the pill
    // pins itself to the top edge, matching the viewer's counter placement.
    return IgnorePointer(
      child: Align(
        alignment: AlignmentDirectional.topEnd,
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.md),
          child: Semantics(
            label: l10n.viewerPageLabel(widget.page + 1, widget.count),
            child: ExcludeSemantics(
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: FuncTokens.imageControl,
                  borderRadius: FuncShape.pill,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FuncSpacing.md,
                    vertical: FuncSpacing.xs,
                  ),
                  child: Text(
                    '${widget.page + 1} / ${widget.count}',
                    // Tabular figures keep the pill width stable while the
                    // page digits change during a scroll.
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: FuncTokens.onImageControl,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
