import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/replica_page_route.dart';
import 'recommended/recommended_illust_page.dart';

import '../../app/icons/app_icons.dart';
import '../../core/navigation/route_observer.dart';
import '../../core/platform/android_intent_channel.dart';
import '../../core/platform/intent_router.dart';
import '../../core/platform/root_back_coordinator.dart';
import '../../core/reverse_image/image_input.dart';
import '../new/new_page.dart';
import '../ranking/ranking_page.dart';
import '../search/search_page.dart';
import '../search/reverse_image_search_page.dart';
import '../search/search_text.dart';
import '../settings/settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.intentSource});

  final AndroidIntentSource? intentSource;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, RouteAware {
  int index = 0;
  late final RootBackCoordinator _backCoordinator;
  late final AndroidIntentSource _intentSource;
  StreamSubscription<AndroidIntentResult>? _intentSubscription;
  bool _routeSubscribed = false;
  bool _externalPageOpen = false;

  @override
  void initState() {
    super.initState();
    _backCoordinator = RootBackCoordinator();
    _intentSource =
        widget.intentSource ?? const MethodChannelAndroidIntentSource();
    WidgetsBinding.instance.addObserver(this);
    _intentSubscription = _intentSource.onNewIntent.listen(
      _handleExternalIntent,
      onError: _handleExternalIntentStreamError,
    );
    unawaited(_readInitialIntent());
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
    unawaited(_intentSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    _backCoordinator.dispose();
    super.dispose();
  }

  Future<void> _readInitialIntent() async {
    try {
      final result = await _intentSource.readInitial();
      if (mounted) _handleExternalIntent(result);
    } on MissingPluginException {
      // Non-Android platforms have no native intent bridge; the picker page
      // still reports its own explicit platform-unavailable state.
    } on PlatformException {
      if (mounted) _showExternalIntentFailure();
    } on Object {
      if (mounted) _showExternalIntentFailure();
    }
  }

  void _handleExternalIntentStreamError(Object error, StackTrace stackTrace) {
    // Desktop/web have no Android event channel. That capability absence is
    // expected; a real Android channel error remains visible to the user.
    if (error is MissingPluginException) return;
    if (mounted) _showExternalIntentFailure();
  }

  void _handleExternalIntent(AndroidIntentResult result) {
    switch (result) {
      case SharedImageAndroidIntent(
        :final contentUri,
        :final mimeType,
        :final sizeBytes,
      ):
        if (_externalPageOpen) return;
        _externalPageOpen = true;
        unawaited(
          Navigator.of(context)
              .push<void>(
                ReplicaPageRoute<void>(
                  builder: (_) => ReverseImageSearchPage(
                    initialReference: ReverseImageInputReference(
                      contentUri: contentUri.toString(),
                      mimeType: mimeType,
                      sizeBytes: sizeBytes,
                      hasReadUriPermission: true,
                      source: ReverseImageInputSource.androidSend,
                    ),
                  ),
                ),
              )
              .whenComplete(() => _externalPageOpen = false),
        );
      case RejectedAndroidIntent():
        _showExternalIntentFailure();
      case RoutedAndroidIntent():
      case IgnoredAndroidIntent():
        break;
    }
  }

  void _showExternalIntentFailure() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(searchText(context, 'searchReverseIntentFailed')),
        ),
      );
    });
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
