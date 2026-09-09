import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';


import '../../app/icons/app_icons.dart';
import '../../core/navigation/route_observer.dart';
import '../../core/platform/android_intent_channel.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/home_shell_metrics.dart';
import '../../app/navigation/routes.dart';
import '../../core/platform/intent_router.dart';
import '../../core/platform/root_back_coordinator.dart';
import '../../core/reverse_image/image_input.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/context.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.intentSource});

  final AndroidIntentSource? intentSource;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, RouteAware, SingleTickerProviderStateMixin {
  late final TabController _navController;

  /// C7: only tabs the user actually opened are built (and kept alive).
  /// IndexedStack still preserves the scroll position and controller state
  /// of every visited tab; unvisited tabs issue no feed requests at cold
  /// start.
  final Set<int> _visitedTabs = {0};
  late final List<Widget?> _tabChildren = List<Widget?>.filled(
    pages.length,
    null,
  );

  late final RootBackCoordinator _backCoordinator;
  final GlobalKey _bottomNavKey = GlobalKey();
  bool _bottomNavMeasureScheduled = false;
  late final AndroidIntentSource _intentSource;
  StreamSubscription<AndroidIntentResult>? _intentSubscription;
  bool _routeSubscribed = false;
  bool _externalPageOpen = false;

  @override
  void initState() {
    super.initState();
    _backCoordinator = RootBackCoordinator();
    // The bottom row is a real TabBar (same machinery as the top tabs):
    // selected indicator slides, ink ripples and icon colors all inherit
    // the TabBar behaviour instead of a hand-rolled approximation.
    _navController = TabController(
      length: pages.length,
      vsync: this,
      initialIndex: 0,
    )..addListener(_onNavChanged);
    _intentSource =
        widget.intentSource ?? const MethodChannelAndroidIntentSource();
    WidgetsBinding.instance.addObserver(this);
    // Publish the real bottom-row height so the Hero flight can clip
    // against the actual chrome instead of a guessed constant.
    _scheduleBottomNavMeasure();
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
  void didChangeMetrics() => _scheduleBottomNavMeasure();

  @override
  void dispose() {
    if (_routeSubscribed) replicaRouteObserver.unsubscribe(this);
    unawaited(_intentSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    _backCoordinator.dispose();
    _navController.dispose();
    super.dispose();
  }

  void _onNavChanged() {
    if (!mounted) return;
    setState(() {});
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
          openReverseImageSearch(
            context,
            initialReference: ReverseImageInputReference(
              contentUri: contentUri.toString(),
              mimeType: mimeType,
              sizeBytes: sizeBytes,
              hasReadUriPermission: true,
              source: ReverseImageInputSource.androidSend,
            ),
          ).whenComplete(() => _externalPageOpen = false),
        );
      case RejectedAndroidIntent():
        _showExternalIntentFailure();
      case RoutedAndroidIntent(:final route):
        // Widget/home-screen deep links: pixivfunc://illusts/<id> opens the
        // illust detail (beta56 behaviour; PRD 08-26-android-home-widgets
        // R3). Unknown or unsupported routes keep the app on the current
        // page instead of navigating somewhere unvalidated.
        if (route is IllustRoute && mounted) {
          unawaited(
            openIllust(context, route.illustId),
          );
        } else if (route is UserRoute && mounted) {
          // C8: user deep links (pixivfunc://users/<id>, /u/<id>,
          // /users/<id>, user.php?id=<id>) were parsed but silently dropped;
          // route them into the existing user page like the detail page does.
          openUser(context, route.userId);
        }
      case IgnoredAndroidIntent():
        break;
    }
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

  void _selectTab(int i) {
    // TabBar already calls TabController.animateTo before invoking onTap.
    // Starting a second animation here resets the indicator/body flight and
    // makes a fast tap feel like it briefly stalls. The callback only owns
    // lazy construction bookkeeping.
    if (_visitedTabs.add(i) && mounted) setState(() {});
  }

  void _showExternalIntentFailure() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showAppSnackBar(context, context.l10n.searchReverseIntentFailed,);
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
              content: Text(
                context.l10n.homeExitHint,
              ),
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

  static const pages = homeShellTabs;

  static const icons = [
    AppIcons.home,
    AppIcons.ranking,
    AppIcons.n,
    AppIcons.search,
    Icons.settings,
  ];

  @override
  Widget build(BuildContext context) {
    _scheduleBottomNavMeasure();
    for (final i in _visitedTabs) {
      _tabChildren[i] ??= pages[i];
    }
    final index = _navController.index;
    final children = [
      for (var i = 0; i < pages.length; i++)
        _tabChildren[i] ?? const SizedBox.shrink(),
    ];
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) => _handleRootBack(didPop),
      child: Scaffold(
        body: IndexedStack(index: index, children: children),
        bottomNavigationBar: SizedBox(
          key: _bottomNavKey,
          child: Padding(
            // Leave a small, real hit-target margin above the gesture area.
            // Translating only the pixels made the bar look higher while its
            // semantic/touch bounds stayed at the very bottom of the screen.
            padding: const EdgeInsets.only(bottom: 8),
            child: BottomAppBar(
              // A real TabBar: same sliding indicator, ripple and colour
              // behaviour as the top TabBar row — full behavioural parity.
              child: TabBar(
                controller: _navController,
                // Keep the C7 lazy-build set in sync with the tapped tab.
                onTap: (i) => _selectTab(i),
                indicatorSize: TabBarIndicatorSize.label,
                indicatorPadding: const EdgeInsets.only(bottom: 5),
                labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                tabs: [
                  for (var i = 0; i < icons.length; i++)
                    Tab(icon: Icon(icons[i], size: 30)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
