import 'package:material_ui/material_ui.dart';

import '../../../../app/motion/motion_tokens.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/theme/func_tokens.dart';
import '../../../../l10n/context.dart';

/// Page position over the artwork ("N / M"), shared by the narrow scroll
/// body and the two-pane pager. Hidden for single-page works, while [page]
/// is null (no artwork on screen) and until the route's entry transition
/// settles; it fades in and out rather than cutting. Never takes pointer
/// input.
class DetailPageCounter extends StatefulWidget {
  const DetailPageCounter({super.key, required this.page, required this.count});

  /// Zero-based page shown as `page + 1`; null hides the pill.
  final int? page;
  final int count;

  @override
  State<DetailPageCounter> createState() => _DetailPageCounterState();
}

class _DetailPageCounterState extends State<DetailPageCounter>
    with SingleTickerProviderStateMixin {
  /// The pill stays out of the entry flight so the Hero lands clean, then
  /// fades in once the route settles. Once shown it stays — on pop it
  /// slides away with the page, not with a Hero.
  bool _routeTransitionComplete = true;
  Animation<double>? _routeAnimation;
  late final AnimationController _fade = AnimationController(vsync: this)
    ..addStatusListener((status) {
      // A finished fade-out drops the pill from the tree.
      if (status.isDismissed && mounted) setState(() {});
    });

  /// The page the pill last showed, kept through its fade-out.
  int? _shownPage;

  bool get _visible =>
      widget.count >= 2 && widget.page != null && _routeTransitionComplete;

  @override
  void initState() {
    super.initState();
    _shownPage = widget.page;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _fade.duration = MotionTokens.resolve(context, MotionTokens.fast);
    final animation = ModalRoute.of(context)?.animation;
    if (!identical(animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
      _routeAnimation = animation;
      // ModalRoute.animation is a proxy that reports `completed` for the
      // route's offstage first frame (hero measurement) and re-points to the
      // real entrance animation afterwards — the listener must be attached
      // unconditionally to catch that swap, which notifies a `forward`
      // status; a `home:` initial route reports completed and never notifies.
      _routeTransitionComplete =
          animation == null || animation.status == AnimationStatus.completed;
      animation?.addStatusListener(_handleRouteAnimationStatus);
    }
    _syncFade();
  }

  @override
  void didUpdateWidget(covariant DetailPageCounter oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFade();
  }

  void _handleRouteAnimationStatus(AnimationStatus status) {
    if (!mounted) return;
    switch (status) {
      case AnimationStatus.completed:
        if (!_routeTransitionComplete) {
          setState(() => _routeTransitionComplete = true);
          _syncFade();
        }
      case AnimationStatus.forward:
        // The entrance transition is running — keep the pill hidden.
        if (_routeTransitionComplete) {
          setState(() => _routeTransitionComplete = false);
          _fade.value = 0;
        }
      // reverse/dismissed belong to the outgoing flight: leave the pill as
      // it is — it slides away with the page and never joins a Hero.
      case AnimationStatus.reverse || AnimationStatus.dismissed:
        break;
    }
  }

  void _syncFade() {
    if (_visible) {
      _shownPage = widget.page;
      _fade.forward();
    } else {
      _fade.reverse();
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = _shownPage;
    // The "multi-page only" check lives here so neither caller repeats it.
    if (widget.count < 2 || page == null || (!_visible && _fade.isDismissed)) {
      return const SizedBox.shrink();
    }
    // Callers hand over the whole image area via Positioned.fill; the pill
    // pins itself to the top edge, matching the viewer's counter placement.
    return IgnorePointer(
      child: Align(
        alignment: AlignmentDirectional.topEnd,
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.md),
          child: ExcludeSemantics(
            excluding: !_visible,
            child: FadeTransition(
              opacity: _fade,
              // ExcludeSemantics owns the hidden state, so the label is
              // there from the first frame of the fade-in.
              alwaysIncludeSemantics: true,
              child: Semantics(
                label: context.l10n.viewerPageLabel(page + 1, widget.count),
                child: ExcludeSemantics(
                  child: PageCountPill(page: page, count: widget.count),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The dark "N / M" capsule over artwork: the detail page's counter and
/// the viewer's jump button wear the same one, so the page position reads
/// the same on both sides of the Hero.
class PageCountPill extends StatelessWidget {
  const PageCountPill({super.key, required this.page, required this.count});

  /// Zero-based page shown as `page + 1`.
  final int page;
  final int count;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
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
          '${page + 1} / $count',
          // Tabular figures keep the pill width stable while the page
          // digits change during a scroll.
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: FuncTokens.onImageControl,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
