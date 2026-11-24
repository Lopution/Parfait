import 'package:material_ui/material_ui.dart';

import 'package:flutter/foundation.dart';

import '../motion/hero_transition.dart'
    show HeroChrome, LiftableBar, LiftableShadow;
import '../motion/motion_tokens.dart';
import '../system_ui.dart';
import '../theme/func_semantic_tokens.dart';
import '../window/desktop_command_bar_scope.dart' show DesktopCommandBarScope;
import 'app_tab_bar.dart';
import 'artwork_controls.dart';

/// Fixed height of a flat desktop or embedded workspace header bar (`NAV-20`
/// / `MasterDetailWorkspace`).
const double kDesktopPageHeaderHeight = 52.0;

/// The single entry point for page top bars: an [AppBar] that keeps the
/// page colour in both states and casts a [ScrollEdgeShadow] over content
/// scrolled under it.
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
    this.actions,
    this.bottom,
    this.tabsBesideTitle = false,
    this.backgroundColor,
    this.contentWidth,
    this.notificationPredicate = defaultScrollNotificationPredicate,
    this.immersion,
    this.overArtwork = true,
    this.entrance,
  }) : assert(
         !tabsBesideTitle || (title != null && bottom is AppTabBar),
         'tabsBesideTitle puts the bottom AppTabBar beside the title: '
         'pass a title and an AppTabBar as bottom',
       );

  final Widget? leading;
  final bool automaticallyImplyLeading;
  final Widget? title;
  final double? titleSpacing;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;

  /// Whether [bottom]'s tabs sit on the title's row instead of under it,
  /// filling the width after the title (the shell's larger forms, NAV-20:
  /// `PageHeader.isWide`). Requires a [title] and an [AppTabBar] [bottom];
  /// the bar is then one toolbar high.
  final bool tabsBesideTitle;

  /// Null keeps the themed page colour; the selection bar sets its own.
  /// A change of colour is a change of mode (entering or leaving
  /// selection): the bar cross-fades into the new one.
  final Color? backgroundColor;

  /// The width of the centred content column the page below caps itself
  /// at (`ContentWidthCap`, `ContentWidths`). The toolbar's leading,
  /// title and actions then line up with that column's edges while the
  /// bar's surface and shadow still span the page (R3). Null keeps the
  /// toolbar at the page's edges.
  final double? contentWidth;

  /// Which scroll notifications count; tab bodies one level down pass
  /// `(n) => n.depth == 1`.
  final ScrollNotificationPredicate notificationPredicate;

  /// For a page that opens on artwork under the bar (the body extends
  /// behind it): 0 draws the toolbar transparent with the theme's
  /// controls ([overArtwork] gives them the [ArtworkControls] look), the title hidden; 1 is
  /// the normal bar. Values between fade one into the other. The
  /// status bar strip stays the page surface throughout, its icons
  /// following the theme: the artwork starts below it rather than under
  /// the clock. The shadow shows only once the bar is fully drawn —
  /// until then the fading surface is the edge. Null is the normal bar.
  final ValueListenable<double>? immersion;

  /// Whether artwork lies under the transparent toolbar: the immersed
  /// controls then take the [ArtworkControls] look. Off (the artwork
  /// starts below the bar), they sit bare: there is nothing to lift them
  /// off.
  final bool overArtwork;

  /// Fades the whole bar in, with the page a Hero flight brings in, so its
  /// controls arrive with a fade rather than a cut. A see-through toolbar
  /// also stays out of a flight over it ([HeroChrome]); a drawn one and
  /// the status strip stay, and the flight passes under them. Null shows
  /// the bar at once.
  final Animation<double>? entrance;

  /// Whether the bar currently hides what scrolls under it. A Hero flight
  /// lands under a see-through bar instead of being clipped below it.
  bool get occludesContent => (immersion?.value ?? 1) > 0;

  @override
  Size get preferredSize => Size.fromHeight(
    tabsBesideTitle
        ? kToolbarHeight
        : kToolbarHeight + (bottom?.preferredSize.height ?? 0),
  );

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
        ? _buildBarWithInset(context, 1)
        : ValueListenableBuilder(
            valueListenable: immersion,
            builder: (context, value, _) =>
                _buildBarWithInset(context, value.clamp(0.0, 1.0).toDouble()),
          );
    return LiftableBar(
      child: AnimatedSwitcher(
        duration: MotionTokens.resolve(context, MotionTokens.chrome),
        switchInCurve: MotionTokens.chromeCurve,
        switchOutCurve: MotionTokens.chromeCurve,
        child: KeyedSubtree(key: ValueKey(widget.backgroundColor), child: bar),
      ),
    );
  }

  /// [child] fading in with [AppTopBar.entrance].
  Widget _entering(Widget child) => switch (widget.entrance) {
    null => child,
    final entrance => FadeTransition(opacity: entrance, child: child),
  };

  /// The page's width, so a [AppTopBar.contentWidth] cap can centre the
  /// toolbar over the content column the page below lays out.
  Widget _buildBarWithInset(BuildContext context, double drawn) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final embedded = EmbeddedHeaderScope.isActiveOf(context);
          final width = widget.contentWidth;
          final free = width == null
              ? 0.0
              : (constraints.maxWidth - width).clamp(0.0, double.infinity);
          // Embedded detail headers sit in a left-aligned workspace column:
          // keep the title flush on the left while stopping trailing actions
          // on `contentWidth`.
          final startInset = embedded ? 0.0 : free / 2;
          final endInset = embedded ? free : free / 2;
          return _buildBar(
            context,
            drawn,
            startInset: startInset,
            endInset: endInset,
            embedded: embedded,
          );
        },
      );

  /// [drawn] is the bar's presence: 1 the normal bar, 0 fully immersed.
  /// [startInset] / [endInset] frame the toolbar over a capped content column.
  Widget _buildBar(
    BuildContext context,
    double drawn, {
    required double startInset,
    required double endInset,
    bool embedded = false,
  }) {
    final theme = Theme.of(context);
    final barTheme = theme.appBarTheme;
    final tokens = theme.extension<FuncSemanticTokens>();
    final desktopOwned = DesktopCommandBarScope.isActiveOf(context);
    final flatWorkspace =
        (embedded || desktopOwned) && widget.immersion == null;
    final surface = widget.backgroundColor != null
        ? widget.backgroundColor!
        : flatWorkspace
        ? theme.scaffoldBackgroundColor
        : barTheme.backgroundColor ?? theme.colorScheme.surface;
    final foreground = barTheme.foregroundColor ?? theme.colorScheme.onSurface;
    final immersed = drawn < 1;
    // Over artwork the controls take the shared artwork look; it fades
    // back to the theme's as the bar's surface takes over.
    final lift = immersed && widget.overArtwork ? 1 - drawn : 0.0;
    final liftedIcons = lift == 0
        ? null
        : IconThemeData.lerp(
            IconThemeData(color: foreground),
            ArtworkControls.iconTheme(context, halo: surface),
            lift,
          );
    final bottom = widget.bottom;
    final title = widget.title;
    // A content column centres (or left-caps, when embedded) the toolbar:
    // the back target starts on the column's left edge, the actions end on
    // its right edge, and the surface and hairline still span the page.
    // On desktop windows owned by DesktopCommandBar, top-level navigation
    // back lives in the command bar rather than duplicating a page arrow
    // (embedded detail panes keep their nested-stack back affordance).
    Widget? leading = widget.leading;
    var automaticallyImplyLeading =
        widget.automaticallyImplyLeading && !(desktopOwned && !embedded);
    List<Widget>? actions = widget.actions;
    EdgeInsetsGeometry? actionsPadding;
    if (startInset > 0) {
      if (leading == null && automaticallyImplyLeading) {
        // Build the implied back button here so it can take the inset;
        // the AppBar's own would sit on the page's edge.
        if (ModalRoute.of(context)?.impliesAppBarDismissal ?? false) {
          leading = BackButton(onPressed: () => Navigator.maybePop(context));
          automaticallyImplyLeading = false;
        }
      }
      if (leading != null) {
        leading = Padding(
          padding: EdgeInsetsDirectional.only(start: startInset),
          child: leading,
        );
      }
    }
    if (endInset > 0) {
      if (actions == null || actions.isEmpty) {
        if (widget.tabsBesideTitle) {
          // No glyphs to inset; an empty trailing gutter stops the tabs
          // (the title row's expanded share) on the column's right edge.
          actions = [
            SizedBox(
              width: (endInset - NavigationToolbar.kMiddleSpacing).clamp(
                0.0,
                double.infinity,
              ),
            ),
          ];
        }
      } else {
        actionsPadding = EdgeInsetsDirectional.only(end: endInset);
      }
    }
    // AppBar wraps leading and actions in its own IconButtonTheme derived from
    // iconTheme/actionsIconTheme (dropping disabledForegroundColor), so apply
    // explicit 0.48 disabled alpha inside those slots without touching the
    // global IconButtonTheme (which would override IconTheme.merge elsewhere).
    final barIconColor = liftedIcons?.color ?? foreground;
    final barIconButtonTheme = IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: barIconColor,
        disabledForegroundColor: barIconColor.withValues(alpha: 0.48),
      ).merge(theme.iconButtonTheme.style),
    );
    if (leading != null) {
      leading = IconButtonTheme(data: barIconButtonTheme, child: leading);
    }
    if (actions != null) {
      actions = [
        for (final action in actions)
          IconButtonTheme(data: barIconButtonTheme, child: action),
      ];
    }
    // A tab row standing in the title is the bar's leading content, not a
    // heading: there is no title text to mark, and the tabs stay tabs.
    final titleIsTabs = title is AppTabBar;
    // On the larger forms the tabs take the toolbar's free width, so the
    // bar is one row high; the whole row fades together when immersed.
    // The bar would make the whole row the page's heading: only the title
    // is, the tabs stay tabs beside it.
    final toolbarTitle = !widget.tabsBesideTitle
        ? title
        : Row(
            children: [
              // The title takes the share the tabs leave it and is cut to
              // that width (ellipsis) rather than pushing them out — large
              // text and actions leave very little toolbar width.
              Flexible(
                child: Semantics(
                  header: true,
                  namesRoute: switch (defaultTargetPlatform) {
                    TargetPlatform.iOS || TargetPlatform.macOS => null,
                    _ => true,
                  },
                  child: title,
                ),
              ),
              const SizedBox(width: FuncSpacing.xl),
              Expanded(child: bottom!),
            ],
          );
    final bottomHeight = widget.tabsBesideTitle
        ? 0.0
        : (bottom?.preferredSize.height ?? 0.0);
    final topPadding = MediaQuery.paddingOf(context).top;
    final toolbar = ValueListenableBuilder(
      valueListenable: _scrolledUnder,
      builder: (context, scrolledUnder, bar) => ScrollEdgeShadow(
        visible: scrolledUnder && !immersed && !flatWorkspace,
        child: bar!,
      ),
      child: AppBar(
        leading: leading,
        automaticallyImplyLeading: automaticallyImplyLeading,
        leadingWidth: startInset > 0 ? startInset + kToolbarHeight : null,
        toolbarHeight: flatWorkspace ? kDesktopPageHeaderHeight : null,
        title: toolbarTitle == null || !immersed
            ? toolbarTitle
            : Opacity(opacity: drawn, child: toolbarTitle),
        excludeHeaderSemantics: widget.tabsBesideTitle || titleIsTabs,
        titleSpacing: embedded && leading == null
            ? (widget.titleSpacing ?? FuncSpacing.xl)
            : startInset > 0 && leading == null
            ? startInset +
                  (widget.titleSpacing ?? NavigationToolbar.kMiddleSpacing)
            : widget.titleSpacing,
        actions: actions,
        actionsPadding: actionsPadding,
        bottom: widget.tabsBesideTitle ? null : bottom,
        backgroundColor:
            widget.backgroundColor ??
            (flatWorkspace
                ? theme.scaffoldBackgroundColor
                : immersed
                ? surface.withValues(alpha: surface.a * drawn)
                : null),
        foregroundColor: flatWorkspace && widget.backgroundColor == null
            ? theme.colorScheme.onSurface
            : immersed
            ? foreground
            : null,
        titleTextStyle: flatWorkspace && widget.backgroundColor == null
            ? theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              )
            : null,
        iconTheme: liftedIcons,
        actionsIconTheme: liftedIcons,
        shape: tokens != null && flatWorkspace
            ? Border(bottom: BorderSide(color: tokens.brandHairline))
            : null,
        // Decouple status-bar icon contrast (estimated from the actual top
        // header fill so dynamic colors stay legible) from the bottom system
        // navigation bar, which always follows the page brightness.
        systemOverlayStyle: immersed || widget.backgroundColor != null
            ? funcSystemBarsStyle(
                immersed
                    ? theme.brightness
                    : ThemeData.estimateBrightnessForColor(surface),
                navBarBackground: theme.brightness,
              )
            : null,
        notificationPredicate: widget.notificationPredicate,
      ),
    );
    final sizedToolbar = !flatWorkspace
        ? toolbar
        : SizedBox(
            height: kDesktopPageHeaderHeight + bottomHeight + topPadding,
            child: toolbar,
          );
    if (widget.entrance == null) {
      return sizedToolbar;
    }
    return HeroChrome(
      holdable: () => !widget.occludesContent,
      child: _entering(sizedToolbar),
    );
  }
}

/// The shadow a top bar casts down over the content scrolled under it
/// (`topBarShadow`), faded in and out on the effects spring (at once under
/// reduced motion). [AppTopBar] draws it; a self-drawn pinned bar that is
/// the page's top edge (the profile tab strip) wraps itself in it.
class ScrollEdgeShadow extends StatelessWidget {
  const ScrollEdgeShadow({
    super.key,
    required this.visible,
    required this.child,
  });

  final bool visible;

  /// The bar, opaque: the shadow is cast by a box as large as it, and the
  /// bar covers the part that falls on itself.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.effectsFast,
    );
    final tokens = FuncSemanticTokens.of(context);
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: duration,
              curve: curve,
              child: Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: [
                  LiftableShadow(
                    shadows: tokens.topBarShadow,
                    visible: visible,
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: -1,
                    height: 1,
                    child: ColoredBox(color: tokens.brandHairline),
                  ),
                ],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Marks top bars hosted inside an embedded desktop detail pane (such as the
/// right navigator of master-detail settings) so they render as flat,
/// left-aligned workspace headers rather than mobile colored bars.
class EmbeddedHeaderScope extends InheritedWidget {
  const EmbeddedHeaderScope({
    super.key,
    this.active = true,
    required super.child,
  });

  final bool active;

  static bool isActiveOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<EmbeddedHeaderScope>()
          ?.active ??
      false;

  @override
  bool updateShouldNotify(EmbeddedHeaderScope oldWidget) =>
      active != oldWidget.active;
}
