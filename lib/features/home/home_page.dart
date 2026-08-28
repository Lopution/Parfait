import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'recommended/recommended_illust_page.dart';

import '../../app/icons/app_icons.dart';
import '../../core/navigation/route_observer.dart';
import '../../core/platform/root_back_coordinator.dart';
import '../new/new_page.dart';
import '../ranking/ranking_page.dart';
import '../search/search_page.dart';
import '../settings/settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, RouteAware {
  int index = 0;
  late final RootBackCoordinator _backCoordinator;
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
    if (_routeSubscribed) return;
    final route = ModalRoute.of(context);
    if (route != null) {
      replicaRouteObserver.subscribe(this, route);
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
    if (_routeSubscribed) replicaRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _backCoordinator.dispose();
    super.dispose();
  }

  void _handleRootBack(bool didPop) {
    if (didPop) return;
    switch (_backCoordinator.handleBackPress()) {
      case RootBackAction.showExitHint:
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('再按一次退出')));
      case RootBackAction.exit:
        SystemNavigator.pop();
    }
  }

  static const pages = [
    RecommendedIllustPage(),
    RankingPage(),
    NewPage(),
    SearchHomePage(),
    SettingsPage(),
  ];

  static const icons = [
    AppIcons.home,
    AppIcons.ranking,
    AppIcons.n,
    AppIcons.search,
    Icons.settings,
  ];

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) => _handleRootBack(didPop),
      child: Scaffold(
        body: IndexedStack(index: index, children: pages),
        bottomNavigationBar: BottomAppBar(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: List.generate(icons.length, (i) {
                return Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => index = i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 5,
                        horizontal: 10,
                      ),
                      child: Icon(
                        icons[i],
                        size: 35,
                        color: index == i
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}
