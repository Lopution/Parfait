import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../app/icons/app_icons.dart';
import '../../app/layout/app_breakpoints.dart';
import '../../core/navigation/route_observer.dart';
import '../../app/navigation/home_shell_metrics.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../core/platform/platform_caps.dart';
import '../../core/platform/root_back_coordinator.dart';
import '../../l10n/context.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, RouteAware {
  late final RootBackCoordinator _backCoordinator;
  bool _chromeClearScheduled = false;
  RouteObserver<ModalRoute<dynamic>> _routeObserver = replicaRouteObserver;
  bool _routeSubscribed = false;

  @override
  void initState() {
    super.initState();
    _backCoordinator = RootBackCoordinator();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer =
        RouteObserverScope.maybeOf(context) ?? replicaRouteObserver;
    final route = ModalRoute.of(context);
    if (_routeSubscribed && identical(observer, _routeObserver)) return;
    if (_routeSubscribed) _routeObserver.unsubscribe(this);
    _routeObserver = observer;
    _routeSubscribed = false;
    if (route != null) {
      _routeObserver.subscribe(this, route);
      _routeSubscribed = true;
    }
  }

  @override
  void didPushNext() => _backCoordinator.onRoutePushed();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _backCoordinator.onLifecycleChange(state);
  }

  @override
  void dispose() {
    if (_routeSubscribed) _routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _backCoordinator.dispose();
    super.dispose();
  }

  /// Wide layouts use a NavigationRail and have no bottom bar — report an
  /// empty measurement so Hero flights clip against the viewport edge
  /// instead of a phantom bar. In narrow layouts the shell-level
  /// [FuncShellBottomNav] publishes its own measured geometry.
  void _scheduleChromeClear() {
    if (_chromeClearScheduled) return;
    _chromeClearScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((timestamp) {
      _chromeClearScheduled = false;
      if (mounted) {
        ProviderScope.containerOf(
          context,
        ).read(homeShellMetricsProvider.notifier).publish(null, 0);
      }
    });
  }

  void _handleRootBack(bool didPop) {
    if (didPop) return;
    // Double-back-to-exit is an Android pattern. Desktop has no root back
    // gesture that reaches this callback; a stray one must not show an
    // exit hint for a window that closes via the title bar.
    if (!ProviderScope.containerOf(
      context,
    ).read(platformCapsProvider).isAndroid) {
      return;
    }
    switch (_backCoordinator.handleBackPress()) {
      case RootBackAction.showExitHint:
        final shellMetrics = ProviderScope.containerOf(
          context,
        ).read(homeShellMetricsProvider);
        // HomePage's ScaffoldMessenger is above the branch-root Scaffold that
        // owns the bottom bar. A floating SnackBar otherwise anchors to the
        // screen edge and covers the bar; reserve the measured bar height
        // (plus a small gap) so the hint stays inside the content area.
        final bottomMargin = (shellMetrics.bottomNavHeight ?? 64) + 12;
        // U4 (R7): the hint's lifetime must equal the exit window — with
        // the default 4s SnackBar the text was still on screen long after
        // the window closed, so it was describing a state that was
        // already false.
        showAppSnackBarOn(
          ScaffoldMessenger.of(context)..hideCurrentSnackBar(),
          context.l10n.homeExitHint,
          duration: RootBackCoordinator.exitWindow,
          margin: EdgeInsets.fromLTRB(16, 0, 16, bottomMargin),
          // The resolved messenger is the root one — it sits above
          // MotionScope, so the gate must come from this page's context.
          animationStyle: snackBarAnimationStyleFor(context),
        );
      case RootBackAction.exit:
        SystemNavigator.pop();
    }
  }

  static const icons = [
    AppIcons.home,
    AppIcons.ranking,
    AppIcons.n,
    AppIcons.search,
    Icons.settings_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = AppBreakpoints.useNavigationRail(width);
    // Three chrome tiers on the same width ladder: bottom bar (<600),
    // compact rail (600-1199), labelled extended rail (>=1200). The rail
    // animates the extended transition itself, so a window resize across
    // the boundary swaps forms without a flash.
    final extendedRail = AppBreakpoints.useExtendedRail(width);
    final index = widget.navigationShell.currentIndex;
    final labels = [
      context.l10n.homeRecommended,
      context.l10n.homeRanking,
      context.l10n.newTitle,
      context.l10n.searchTitle,
      context.l10n.settingsTitle,
    ];
    // Narrow layout: the shell-level bar floats over the branch strip —
    // a pushed route slides it away via the covered provider.
    // Wide layout: no bar at all; clear the metric so Hero flights do not
    // clip against a phantom edge.
    if (wide) _scheduleChromeClear();
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) => _handleRootBack(didPop),
      child: Scaffold(
        // Keyboard overlay, not resize: this Scaffold's body is the branch
        // navigator — resizing it compresses every pushed route regardless
        // of the leaf page's own resizeToAvoidBottomInset (the search
        // input page's `false` was previously defeated here).
        resizeToAvoidBottomInset: false,
        body: wide
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: index,
                    onDestinationSelected: widget.navigationShell.goBranch,
                    extended: extendedRail,
                    // `extended` requires labelType null/none; the compact
                    // rail keeps labels under every icon.
                    labelType: extendedRail
                        ? null
                        : NavigationRailLabelType.all,
                    destinations: [
                      for (var i = 0; i < icons.length; i++)
                        NavigationRailDestination(
                          icon: Icon(icons[i], size: 26),
                          label: Text(labels[i]),
                        ),
                    ],
                  ),
                  const VerticalDivider(thickness: 1, width: 1),
                  Expanded(child: widget.navigationShell),
                ],
              )
            : widget.navigationShell,
      ),
    );
  }
}
