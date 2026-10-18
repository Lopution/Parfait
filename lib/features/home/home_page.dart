import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/widgets/app_snack_bar.dart';
import '../../core/navigation/home_destination.dart';
import '../../core/navigation/route_observer.dart';
import '../../core/platform/platform_caps.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';

/// How long a first back at the start page keeps a second one armed to
/// leave the app, and so how long its hint stays.
const homeExitWindow = Duration(seconds: 2);

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with WidgetsBindingObserver, RouteAware {
  RouteObserver<ModalRoute<dynamic>> _routeObserver = replicaRouteObserver;
  ModalRoute<dynamic>? _route;
  Timer? _exitArmed;
  VoidCallback? _hideExitHint;

  /// The start page this run opened on, taken from the first settings it
  /// had.
  HomeDestination? _launched;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final observer =
        RouteObserverScope.maybeOf(context) ?? replicaRouteObserver;
    if (identical(route, _route) && identical(observer, _routeObserver)) {
      return;
    }
    if (_route != null) _routeObserver.unsubscribe(this);
    _routeObserver = observer;
    _route = route;
    if (route != null) _routeObserver.subscribe(this, route);
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final from = oldWidget.navigationShell;
    final to = widget.navigationShell;
    if (from.currentIndex != to.currentIndex ||
        from.shellRouteContext.routerState.uri !=
            to.shellRouteContext.routerState.uri) {
      _disarmExit();
    }
  }

  // A back only exits right after the hint: leaving the start page,
  // covering it or leaving the app ends the window, so a later back there
  // starts over instead of closing the app.
  @override
  void didPushNext() => _disarmExit();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _disarmExit();
  }

  @override
  void dispose() {
    if (_route != null) _routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _disarmExit();
    super.dispose();
  }

  void _disarmExit() {
    _exitArmed?.cancel();
    _exitArmed = null;
    _hideExitHint?.call();
    _hideExitHint = null;
  }

  void _backAtStart() {
    if (_exitArmed != null) {
      _disarmExit();
      unawaited(SystemNavigator.pop());
      return;
    }
    _exitArmed = Timer(homeExitWindow, _disarmExit);
    _hideExitHint = showAppSnackBar(
      context,
      context.l10n.homeExitHint,
      duration: homeExitWindow,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = widget.navigationShell;
    // The start page's own root confirms before it hands back to the
    // system (on Android, the one platform with a root back). Every other
    // branch root claims the back event and returns to the start page.
    final settings = ref.watch(settingsProvider).value;
    if (settings != null) _launched ??= homeStartDestination(settings);
    final start = homeBackDestination(settings, _launched);
    final atStart =
        shell.currentIndex == start.branchIndex &&
        shell.shellRouteContext.routerState.uri.path == start.rootPath;
    final confirmExit = ref.watch(platformCapsProvider).isAndroid;
    return PopScope<void>(
      canPop: atStart && !confirmExit,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (shell.currentIndex != start.branchIndex) {
          shell.goBranch(start.branchIndex);
        } else if (atStart) {
          _backAtStart();
        }
      },
      child: Scaffold(
        // Keyboard overlay, not resize: this Scaffold's body is the branch
        // navigator — resizing it compresses every pushed route regardless
        // of the leaf page's own resizeToAvoidBottomInset.
        resizeToAvoidBottomInset: false,
        body: shell,
      ),
    );
  }
}
