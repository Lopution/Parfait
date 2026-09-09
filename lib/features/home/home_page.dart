import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
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
  const HomePage({super.key, required this.navigationShell, this.intentSource});

  final StatefulNavigationShell navigationShell;
  final AndroidIntentSource? intentSource;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver, RouteAware {
  late final RootBackCoordinator _backCoordinator;
  final GlobalKey _bottomNavKey = GlobalKey();
  bool _bottomNavMeasureScheduled = false;
  late final AndroidIntentSource _intentSource;
  StreamSubscription<AndroidIntentResult>? _intentSubscription;
  RouteObserver<ModalRoute<dynamic>> _routeObserver = replicaRouteObserver;
  bool _routeSubscribed = false;
  bool _externalPageOpen = false;

  @override
  void initState() {
    super.initState();
    _backCoordinator = RootBackCoordinator();
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
          unawaited(openIllust(context, route.illustId));
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

  void _showExternalIntentFailure() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showAppSnackBar(context, context.l10n.searchReverseIntentFailed);
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
    Icons.settings,
  ];

  @override
  Widget build(BuildContext context) {
    _scheduleBottomNavMeasure();
    final index = widget.navigationShell.currentIndex;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) => _handleRootBack(didPop),
      child: Scaffold(
        body: widget.navigationShell,
        bottomNavigationBar: SizedBox(
          key: _bottomNavKey,
          child: Padding(
            // Leave a small, real hit-target margin above the gesture area.
            // Translating only the pixels made the bar look higher while its
            // semantic/touch bounds stayed at the very bottom of the screen.
            padding: const EdgeInsets.only(bottom: 8),
            child: NavigationBar(
              selectedIndex: index,
              onDestinationSelected: widget.navigationShell.goBranch,
              destinations: [
                NavigationDestination(
                  icon: Icon(icons[0], size: 30),
                  label: context.l10n.homeRecommended,
                ),
                NavigationDestination(
                  icon: Icon(icons[1], size: 30),
                  label: context.l10n.homeRanking,
                ),
                NavigationDestination(
                  icon: Icon(icons[2], size: 30),
                  label: context.l10n.newTitle,
                ),
                NavigationDestination(
                  icon: Icon(icons[3], size: 30),
                  label: context.l10n.searchTitle,
                ),
                NavigationDestination(
                  icon: Icon(icons[4], size: 30),
                  label: context.l10n.settingsTitle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
