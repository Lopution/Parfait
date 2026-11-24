import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../../app/layout/app_breakpoints.dart';
import '../../../../app/motion/page_transitions.dart' show TurnCurve;
import '../../../../app/navigation/home_shell_metrics.dart';
import '../../../../app/navigation/route_animation.dart';
import '../../../../app/theme/func_semantic_tokens.dart';

/// Frames wide flat detail routes (`>= 960x600`) inside a scrimmed modal card
/// over the live feed while keeping [child]'s state anchored across resizes
/// via a persistent [GlobalKey].
class DetailOverlayFrame extends StatefulWidget {
  const DetailOverlayFrame({super.key, required this.child});

  final Widget child;

  /// Whether [context] sits inside an active bounded modal [DetailOverlayFrame].
  static bool isActiveOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DetailOverlayScope>() != null;

  @override
  State<DetailOverlayFrame> createState() => _DetailOverlayFrameState();
}

class _DetailOverlayScope extends InheritedWidget {
  const _DetailOverlayScope({required super.child});

  @override
  bool updateShouldNotify(_DetailOverlayScope oldWidget) => false;
}

class _DetailOverlayFrameState extends State<DetailOverlayFrame> {
  static final _scrimCurves = Expando<Animation<double>>();

  final _childKey = GlobalKey();
  int? _scrimPointer;
  bool _popping = false;
  HomeShellModalScrim? _modalScrim;
  int? _branchIndex;
  bool _registered = false;

  static Animation<double> _curvedScrimAnimation(Animation<double> raw) =>
      _scrimCurves[raw] ??= TurnCurve.drive(
        raw,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncModalScrim();
  }

  @override
  void didUpdateWidget(DetailOverlayFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncModalScrim();
  }

  @override
  void deactivate() {
    _unregisterModalScrim();
    super.deactivate();
  }

  @override
  void dispose() {
    _unregisterModalScrim();
    super.dispose();
  }

  void _handleScrimDismiss() => unawaited(_dismissOverlay());

  void _unregisterModalScrim() {
    if (!_registered) return;
    _modalScrim?.unregister(this, branchIndex: _branchIndex);
    _registered = false;
  }

  void _syncModalScrim() {
    if (!mounted) return;
    final scrim = HomeShellChrome.maybeOf(context)?.modalScrim;
    final branchIndex = HomeShellBranchScope.maybeOf(context);
    final route = ModalRoute.of(context);
    // Hero's measurement frame overrides ModalRoute.animation to 1.0, so prefer
    // RouteAnimationScope's underlying controller to keep frame-0 scrim at 0.0.
    final routeAnimation = RouteAnimationScope.of(context) ?? route?.animation;
    final outerSize = HomeShellChrome.contentSizeOf(context);
    // Keep the modal frame & scrim active throughout popping until dismissal.
    final hasRouteBelow = !(route?.isFirst ?? true);
    final bounded =
        hasRouteBelow &&
        routeAnimation != null &&
        AppBreakpoints.useBoundedDetailOverlayOf(context, outerSize);

    if (!bounded || scrim == null) {
      _unregisterModalScrim();
      _modalScrim = scrim;
      _branchIndex = branchIndex;
      return;
    }

    if (!identical(_modalScrim, scrim) || _branchIndex != branchIndex) {
      _unregisterModalScrim();
    }
    _modalScrim = scrim;
    _branchIndex = branchIndex;
    _registered = true;
    scrim.register(
      owner: this,
      branchIndex: branchIndex,
      animation: _curvedScrimAnimation(routeAnimation),
      secondaryAnimation: route?.secondaryAnimation,
      onDismiss: _handleScrimDismiss,
    );
  }

  Future<void> _dismissOverlay() async {
    if (_popping || !mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _popping = true;
    try {
      await Navigator.maybePop(context);
    } finally {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        _popping = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = KeyedSubtree(key: _childKey, child: widget.child);
    final outerSize = HomeShellChrome.contentSizeOf(context);
    final hasRouteBelow = !(ModalRoute.of(context)?.isFirst ?? true);
    final bounded =
        hasRouteBelow &&
        AppBreakpoints.useBoundedDetailOverlayOf(context, outerSize);
    if (_modalScrim != null && bounded != _registered) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncModalScrim();
      });
    }
    if (!bounded) return content;

    final tokens = FuncSemanticTokens.of(context);
    final outerChrome = HomeShellChrome.maybeOf(context);
    final outerMedia = MediaQuery.of(context);
    // Compute the bounded card size directly from MediaQuery instead of a
    // LayoutBuilder so crossing the 960x600 threshold never reparents
    // `_childKey` across build and layout scopes or runs child
    // `didChangeDependencies` during performLayout.
    final cardWidth = math.min(
      1680.0,
      math.max(
        0.0,
        outerSize.width - outerMedia.padding.horizontal - FuncSpacing.lg * 2,
      ),
    );
    final cardHeight = math.max(
      0.0,
      outerSize.height - outerMedia.padding.vertical - FuncSpacing.md * 2,
    );
    final cardSize = Size(cardWidth, cardHeight);
    final framedChild = MediaQuery(
      data: outerMedia
          .copyWith(size: cardSize)
          .removePadding(
            removeTop: true,
            removeBottom: true,
            removeLeft: true,
            removeRight: true,
          ),
      child: _DetailOverlayScope(
        child: outerChrome == null
            ? content
            : HomeShellChrome(
                bottomBarExtent: 0,
                railExtent: 0,
                bottomBarVisibleExtent: outerChrome.bottomBarVisibleExtent,
                bottomBarVisibility: outerChrome.bottomBarVisibility,
                onBranchRootScroll: outerChrome.onBranchRootScroll,
                child: content,
              ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) => _scrimPointer = event.pointer,
          onPointerUp: (event) {
            if (_scrimPointer == event.pointer) {
              _scrimPointer = null;
              unawaited(_dismissOverlay());
            }
          },
          onPointerCancel: (event) {
            if (_scrimPointer == event.pointer) {
              _scrimPointer = null;
            }
          },
          child: GestureDetector(
            key: const ValueKey('detail-overlay-scrim'),
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(_dismissOverlay()),
            child: const ColoredBox(color: Color(0x990C0B0E)),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FuncSpacing.lg,
              vertical: FuncSpacing.md,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1680),
                child: SizedBox.expand(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: FuncShape.dialog,
                      border: Border.all(color: tokens.brandHairline),
                      boxShadow: tokens.layerLift,
                    ),
                    child: ClipRRect(
                      borderRadius: FuncShape.dialog,
                      child: framedChild,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
