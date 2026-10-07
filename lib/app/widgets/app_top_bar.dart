import 'package:material_ui/material_ui.dart';

import 'package:flutter/foundation.dart';

import '../motion/motion_tokens.dart';
import '../system_ui.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';

/// The single entry point for page top bars: an [AppBar] that keeps the
/// page colour in both states and marks content scrolled under it with a
/// [ScrollEdgeLine] along its bottom edge.
///
/// "Scrolled under" is the [AppBar] rule, tracked here because the bar
/// does not expose it: a [ScrollUpdateNotification] that passes
/// [notificationPredicate] from a vertical scrollable past its leading
/// edge. `announceTabScroll` drives it like any other notification.
class AppTopBar extends StatefulWidget implements PreferredSizeWidget {
  const AppTopBar({
    super.key,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.title,
    this.titleSpacing,
    this.centerTitle,
    this.actions,
    this.bottom,
    this.backgroundColor,
    this.notificationPredicate = defaultScrollNotificationPredicate,
    this.immersion,
    this.entrance,
  });

  final Widget? leading;
  final bool automaticallyImplyLeading;
  final Widget? title;
  final double? titleSpacing;
  final bool? centerTitle;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;

  /// Null keeps the themed page colour; the selection bar sets its own.
  final Color? backgroundColor;

  /// Which scroll notifications count; tab bodies one level down pass
  /// `(n) => n.depth == 1`.
  final ScrollNotificationPredicate notificationPredicate;

  /// For a page that opens on artwork under the bar (the body extends
  /// behind it): 0 draws the bar transparent, its controls light on a dark
  /// scrim with a shadow so they read on any image, the title hidden; 1 is
  /// the normal bar. Values between fade one into the other. The edge line
  /// shows only once the bar is fully drawn — until then the fading
  /// surface is the edge. Null is the normal bar.
  final ValueListenable<double>? immersion;

  /// Fades the whole bar in. A Hero flight that lands under a see-through
  /// bar is drawn over it; the page holds the bar back until the image has
  /// landed, so its controls arrive with a fade rather than a cut. Null
  /// shows the bar at once.
  final Animation<double>? entrance;

  /// Whether the bar currently hides what scrolls under it. A Hero flight
  /// lands under a see-through bar instead of being clipped below it.
  bool get occludesContent => (immersion?.value ?? 1) > 0;

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  State<AppTopBar> createState() => _AppTopBarState();
}

class _AppTopBarState extends State<AppTopBar> {
  ScrollNotificationObserverState? _observer;

  // A notifier, not setState: the line rebuilds, the bar does not.
  final _scrolledUnder = ValueNotifier(false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observer?.removeListener(_handleScrollNotification);
    _observer = ScrollNotificationObserver.maybeOf(context);
    _observer?.addListener(_handleScrollNotification);
  }

  @override
  void dispose() {
    _observer?.removeListener(_handleScrollNotification);
    _scrolledUnder.dispose();
    super.dispose();
  }

  void _handleScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification ||
        !widget.notificationPredicate(notification)) {
      return;
    }
    final metrics = notification.metrics;
    _scrolledUnder.value = switch (metrics.axisDirection) {
      AxisDirection.down => metrics.extentBefore > 0,
      AxisDirection.up => metrics.extentAfter > 0,
      // A horizontal scroller under the same predicate says nothing about
      // what is under the bar.
      AxisDirection.left || AxisDirection.right => _scrolledUnder.value,
    };
  }

  @override
  Widget build(BuildContext context) {
    final immersion = widget.immersion;
    final bar = immersion == null
        ? _buildBar(context, 1)
        : ValueListenableBuilder(
            valueListenable: immersion,
            builder: (context, value, _) =>
                _buildBar(context, value.clamp(0.0, 1.0).toDouble()),
          );
    final entrance = widget.entrance;
    return entrance == null
        ? bar
        : FadeTransition(opacity: entrance, child: bar);
  }

  /// [drawn] is the bar's presence: 1 the normal bar, 0 fully immersed.
  Widget _buildBar(BuildContext context, double drawn) {
    final theme = Theme.of(context);
    final barTheme = theme.appBarTheme;
    final surface =
        widget.backgroundColor ??
        barTheme.backgroundColor ??
        theme.colorScheme.surface;
    final foreground = barTheme.foregroundColor ?? theme.colorScheme.onSurface;
    final immersed = drawn < 1;
    final controls = Color.lerp(FuncTokens.onImageControl, foreground, drawn)!;
    final iconTheme = IconThemeData(
      color: controls,
      shadows: immersed
          ? [
              Shadow(
                color: FuncTokens.imageControl.withValues(
                  alpha: FuncTokens.imageControl.a * (1 - drawn),
                ),
                blurRadius: FuncSpacing.sm,
              ),
            ]
          : null,
    );
    final title = widget.title;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        if (immersed)
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 1 - drawn,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [FuncTokens.imageControl, FuncTokens.transparent],
                    ),
                  ),
                ),
              ),
            ),
          ),
        AppBar(
          leading: widget.leading,
          automaticallyImplyLeading: widget.automaticallyImplyLeading,
          title: title == null || !immersed
              ? title
              : Opacity(opacity: drawn, child: title),
          titleSpacing: widget.titleSpacing,
          centerTitle: widget.centerTitle,
          actions: widget.actions,
          bottom: widget.bottom,
          backgroundColor: immersed
              ? surface.withValues(alpha: surface.a * drawn)
              : widget.backgroundColor,
          foregroundColor: immersed ? controls : null,
          iconTheme: immersed ? iconTheme : null,
          actionsIconTheme: immersed ? iconTheme : null,
          // Light status icons over the scrim until the surface is mostly
          // drawn; the navigation bar keeps following the page.
          systemOverlayStyle: immersed
              ? funcSystemBarsStyle(
                  theme.brightness,
                  statusBackground: drawn < 0.5
                      ? Brightness.dark
                      : theme.brightness,
                )
              : null,
          notificationPredicate: widget.notificationPredicate,
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ValueListenableBuilder(
            valueListenable: _scrolledUnder,
            builder: (context, scrolledUnder, _) =>
                ScrollEdgeLine(visible: scrolledUnder && !immersed),
          ),
        ),
      ],
    );
  }
}

/// The hairline at the bottom edge of a top bar while content is scrolled
/// under it, faded in and out on the effects spring (at once under reduced
/// motion). [AppTopBar] draws it; a self-drawn pinned bar that is the
/// page's top edge (the profile tab strip) puts it at its own bottom.
class ScrollEdgeLine extends StatelessWidget {
  const ScrollEdgeLine({super.key, required this.visible});

  final bool visible;

  /// One logical pixel, the app's divider thickness.
  static const thickness = 1.0;

  @override
  Widget build(BuildContext context) {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.effectsFast,
    );
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: duration,
        curve: curve,
        child: SizedBox(
          height: thickness,
          child: ColoredBox(color: FuncSemanticTokens.of(context).divider),
        ),
      ),
    );
  }
}
