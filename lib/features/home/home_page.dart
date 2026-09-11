import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../app/icons/app_icons.dart';
import '../../app/layout/app_breakpoints.dart';
import '../../core/navigation/route_observer.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/home_shell_metrics.dart';
import '../../app/widgets/settings_action_button.dart';
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
  final GlobalKey _bottomNavKey = GlobalKey();
  bool _bottomNavMeasureScheduled = false;
  RouteObserver<ModalRoute<dynamic>> _routeObserver = replicaRouteObserver;
  bool _routeSubscribed = false;

  @override
  void initState() {
    super.initState();
    _backCoordinator = RootBackCoordinator();
    WidgetsBinding.instance.addObserver(this);
    // Publish the real bottom-row height so the Hero flight can clip
    // against the actual chrome instead of a guessed constant.
    _scheduleBottomNavMeasure();
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
  void didChangeMetrics() => _scheduleBottomNavMeasure();

  @override
  void dispose() {
    if (_routeSubscribed) _routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _backCoordinator.dispose();
    super.dispose();
  }

  void _measureBottomNav(Duration _) {
    final box = _bottomNavKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.height > 0) {
      final origin = box.localToGlobal(Offset.zero);
      ProviderScope.containerOf(context)
          .read(homeShellMetricsProvider.notifier)
          .publish(origin.dy, box.size.height);
    }
  }

  void _scheduleBottomNavMeasure() {
    if (_bottomNavMeasureScheduled) return;
    _bottomNavMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((timestamp) {
      _bottomNavMeasureScheduled = false;
      if (mounted) _measureBottomNav(timestamp);
    });
  }

  /// Wide layouts use a NavigationRail and have no bottom bar — report an
  /// empty measurement so Hero flights clip against the viewport edge instead
  /// of a phantom bar.
  void _scheduleChromeClear() {
    if (_bottomNavMeasureScheduled) return;
    _bottomNavMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((timestamp) {
      _bottomNavMeasureScheduled = false;
      if (mounted) {
        ProviderScope.containerOf(
          context,
        ).read(homeShellMetricsProvider.notifier).publish(null, 0);
      }
    });
  }

  void _handleRootBack(bool didPop) {
    if (didPop) return;
    switch (_backCoordinator.handleBackPress()) {
      case RootBackAction.showExitHint:
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          // U4 (R7): the hint's lifetime must equal the exit window — with
          // the default 4s SnackBar the text was still on screen long after
          // the window closed, so it was describing a state that was
          // already false. Floating + M3 fade keeps it near the thumb; the
          // in/out animation is shortened so the whole cycle fits the
          // 1-second window the hint describes.
          ..showSnackBar(
            SnackBar(
              content: Text(context.l10n.homeExitHint),
              duration: RootBackCoordinator.exitWindow,
              behavior: SnackBarBehavior.floating,
            ),
            snackBarAnimationStyle: const AnimationStyle(
              // M2 floating fades inside the 0.4-1.0 interval, so a 120ms
              // animation only paints ~72ms of fade — read as "no
              // animation" on device. 200ms keeps the whole hint within the
              // 1s exit window while the fade is perceptible.
              duration: MotionTokens.medium,
              reverseDuration: MotionTokens.fast,
            ),
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
    Icons.person_outline,
  ];

  @override
  Widget build(BuildContext context) {
    final wide = AppBreakpoints.useNavigationRail(
      MediaQuery.sizeOf(context).width,
    );
    if (wide) {
      _scheduleChromeClear();
    } else {
      _scheduleBottomNavMeasure();
    }
    final index = widget.navigationShell.currentIndex;
    final labels = [
      context.l10n.homeRecommended,
      context.l10n.homeRanking,
      context.l10n.newTitle,
      context.l10n.searchTitle,
      context.l10n.homeMe,
    ];
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) => _handleRootBack(didPop),
      child: Scaffold(
        body: wide
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: index,
                    onDestinationSelected: widget.navigationShell.goBranch,
                    labelType: NavigationRailLabelType.all,
                    destinations: [
                      for (var i = 0; i < icons.length; i++)
                        NavigationRailDestination(
                          icon: Icon(icons[i], size: 26),
                          label: Text(labels[i]),
                        ),
                    ],
                    trailing: const Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: SettingsActionButton(),
                        ),
                      ),
                    ),
                  ),
                  const VerticalDivider(thickness: 1, width: 1),
                  Expanded(child: widget.navigationShell),
                ],
              )
            : widget.navigationShell,
        bottomNavigationBar: wide
            ? null
            : SizedBox(
                key: _bottomNavKey,
                // NavigationBar already includes the M3 80dp row plus the
                // bottom safe-area inset; the extra margin the old
                // BottomAppBar needed left a strip of scaffold background
                // under the bar.
                child: NavigationBar(
                  selectedIndex: index,
                  onDestinationSelected: widget.navigationShell.goBranch,
                  destinations: [
                    for (var i = 0; i < icons.length; i++)
                      NavigationDestination(
                        icon: Icon(icons[i], size: 30),
                        label: labels[i],
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
