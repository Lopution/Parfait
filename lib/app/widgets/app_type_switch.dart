import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

import '../motion/motion_tokens.dart';
import '../theme/func_semantic_tokens.dart';
import 'app_segmented_button.dart';

/// Compact segmented type switch (R6): a 48dp row at the default scale,
/// left-aligned, horizontally scrollable when the labels overflow.
/// Tapping the already-selected option calls [onSelected] with the
/// current value so hosts can treat it as a re-tap (scroll to top).
class AppTypeSwitch<T> extends StatelessWidget {
  const AppTypeSwitch({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  }) : assert(options.length >= 2 && options.length <= 4);

  final List<({T value, String label})> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          // The row scrolls on its own physics. Inherited ones leak: inside
          // PullToRefresh a sideways drag would feed EasyRefresh's physics
          // and arm a refresh, and the app's always-scrollable parent makes
          // a row that fits claim the drag, so a swipe starting on it never
          // reaches RootSwipeSwitcher. Parentless bouncing only takes drags
          // when the segments overflow.
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(physics: const BouncingScrollPhysics()),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.md),
              child: AppSegmentedButton<T>(
                selected: selected,
                onSelected: onSelected,
                // The host sees a re-tap as the current value again.
                onReselected: () => onSelected(selected),
                segments: [
                  for (final option in options)
                    AppSegment<T>(value: option.value, label: option.label),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sliver form of [AppTypeSwitch] for feed headers: floats back in on an
/// upward drag after scrolling away, using the same show/hide motion as
/// the bottom navigation bar.
class SliverAppTypeSwitch<T> extends StatelessWidget {
  const SliverAppTypeSwitch({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  }) : assert(options.length >= 2 && options.length <= 4);

  final List<({T value, String label})> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final animationStyle = MotionTokens.enabled(context)
        ? AnimationStyle(
            duration: MotionTokens.resolve(context, MotionTokens.navBarShow),
            curve: MotionTokens.navBarShowCurve,
            reverseDuration: MotionTokens.resolve(
              context,
              MotionTokens.navBarHide,
            ),
            reverseCurve: MotionTokens.navBarHideCurve,
          )
        : AnimationStyle.noAnimation;
    return _NonNegativeOverlap(
      child: SliverFloatingHeader(
        animationStyle: animationStyle,
        child: AppTypeSwitch<T>(
          options: options,
          selected: selected,
          onSelected: onSelected,
        ),
      ),
    );
  }
}

/// PullToRefresh lays out with `clamping: false`, so an overscroll hands
/// the first sliver a *negative* `constraints.overlap`
/// (`viewport.dart` `_attemptLayout`: `min(0, -centerOffset)`).
/// [SliverFloatingHeader] parks at `min(overlap, 0)` — a negative overlap
/// pins it to the viewport top while the list overshoots, and the
/// above-the-list refresh indicator paints over the switch row. Clamping
/// the overlap at zero lets the row travel down with the list instead.
/// Positive overlaps pass through untouched, so the Hero return clip —
/// measured off the next sliver's overlap — stays unchanged.
class _NonNegativeOverlap extends SingleChildRenderObjectWidget {
  const _NonNegativeOverlap({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNonNegativeOverlap();
}

class _RenderNonNegativeOverlap extends RenderProxySliver {
  @override
  void performLayout() {
    child!.layout(
      constraints.copyWith(
        overlap: constraints.overlap < 0 ? 0.0 : constraints.overlap,
      ),
      parentUsesSize: true,
    );
    final childGeometry = child!.geometry;
    geometry = childGeometry?.copyWith(
      paintOrigin: math.max(
        childGeometry.paintOrigin,
        _pinnedOverlap(childGeometry),
      ),
    );
  }

  /// While the row is floated (its slot scrolled fully out), a NestedScrollView
  /// body underlaps the pinned outer headers: the enclosing *body* sliver
  /// (e.g. the outer viewport's SliverFillRemaining) carries that encroachment
  /// in its own `constraints.overlap`, while inner slivers see zero. Parking
  /// the revealed row at that offset keeps it below the pinned chrome instead
  /// of under it. In a standalone CustomScrollView there is no enclosing
  /// sliver, so this reports zero and the row floats at the viewport edge as
  /// usual.
  double _pinnedOverlap(SliverGeometry childGeometry) {
    // Once the slot is only partially scrolled off, the row is still in the
    // list's flow — its natural position is correct and no inset applies.
    if (constraints.scrollOffset < childGeometry.scrollExtent) {
      return 0;
    }
    RenderObject? node = parent;
    while (node != null) {
      final ancestor = node.parent;
      if (node is RenderSliver && ancestor is RenderNestedScrollViewViewport) {
        return math.max(node.constraints.overlap, 0.0);
      }
      node = ancestor;
    }
    return 0;
  }
}
