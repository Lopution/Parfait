import 'package:material_ui/material_ui.dart';

import '../motion/motion_tokens.dart';
import '../theme/func_semantic_tokens.dart';

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
    return Stack(
      fit: StackFit.passthrough,
      children: [
        AppBar(
          leading: widget.leading,
          automaticallyImplyLeading: widget.automaticallyImplyLeading,
          title: widget.title,
          titleSpacing: widget.titleSpacing,
          centerTitle: widget.centerTitle,
          actions: widget.actions,
          bottom: widget.bottom,
          backgroundColor: widget.backgroundColor,
          notificationPredicate: widget.notificationPredicate,
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ValueListenableBuilder(
            valueListenable: _scrolledUnder,
            builder: (context, scrolledUnder, _) =>
                ScrollEdgeLine(visible: scrolledUnder),
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
