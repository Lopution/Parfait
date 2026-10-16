import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/navigation/func_page.dart';
import 'package:parfait/app/navigation/route_animation.dart';
import 'package:parfait/app/widgets/home_branch_stack.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/profile/profile_edit_controller.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/profile/profile_edit_models.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/features/history/history_page.dart';
import 'package:parfait/features/profile/profile_edit_page.dart';
import 'package:parfait/features/profile/user_page.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';

Future<void> _sendBackGestureMethod(
  String method, [
  Map<String, dynamic>? arguments,
]) {
  final data = const StandardMethodCodec().encodeMethodCall(
    MethodCall(method, arguments),
  );
  return TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('flutter/backgesture', data, (_) {});
}

/// Android's predictive back, starting at the left edge.
/// Whether the lifted-Hero hole of a moving page covers [global]: the
/// painted even-odd clip leaves it out. Null when no page has a hole.
bool? _liftedHoleAt(WidgetTester tester, Offset global) {
  final clips = tester.layers.whereType<ClipPathLayer>().where(
    (layer) => layer.clipPath!.fillType == PathFillType.evenOdd,
  );
  if (clips.isEmpty) return null;
  final clip = clips.single;
  final chain = <Layer>[clip];
  for (var up = clip.parent; up != null; up = up.parent) {
    chain.add(up);
  }
  // From below the root, whose transform maps logical to device pixels.
  final transform = Matrix4.identity();
  for (var i = chain.length - 2; i > 0; i--) {
    (chain[i] as ContainerLayer).applyTransform(chain[i - 1], transform);
  }
  final local = MatrixUtils.transformPoint(Matrix4.inverted(transform), global);
  return !clip.clipPath!.contains(local);
}

Future<void> _startBackGesture() => _sendBackGestureMethod('startBackGesture', {
  'touchOffset': <double>[5.0, 300.0],
  'progress': 0.0,
  'swipeEdge': 0,
});

/// The predictive back swipe, 100 px in, at [progress].
Future<void> _dragBackGesture(double progress) =>
    _sendBackGestureMethod('updateBackGestureProgress', {
      'touchOffset': <double>[100.0, 300.0],
      'progress': progress,
      'swipeEdge': 0,
    });

Finder _sharedElementTransition() => find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString().contains(
    'PredictiveBackSharedElementPageTransition',
  ),
);

/// Pumps a bare Navigator whose initial route is a [FuncPage]; the page's
/// button pushes a second FuncPage showing [second] and hands the route back
/// through the return value, settled unless [settle] is false.
Future<PageRoute<void>> _pushSecondPage(
  WidgetTester tester, {
  Duration duration = const Duration(milliseconds: 800),
  PageTransitionStyle transitionStyle = PageTransitionStyle.system,
  Widget? home,
  Widget second = const Text('page b'),
  bool settle = true,
}) async {
  late final PageRoute<void> pushed;
  late BuildContext rootContext;
  PageRoute<void> page(Widget child) =>
      FuncPage<void>(
            transitionDuration: duration,
            reverseTransitionDuration: duration,
            transitionStyle: transitionStyle,
            child: child,
          ).createRoute(rootContext)
          as PageRoute<void>;
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Builder(
        builder: (context) {
          rootContext = context;
          return Navigator(
            onGenerateRoute: (_) => page(
              Builder(
                builder: (context) => TextButton(
                  onPressed: () {
                    pushed = page(second);
                    Navigator.of(context).push(pushed);
                  },
                  child: home ?? const Text('page a'),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.tap(find.text('page a'));
  if (!settle) {
    await tester.pump();
    return pushed;
  }
  await tester.pumpAndSettle();
  expect(find.text('page b'), findsOneWidget);
  return pushed;
}

/// Full-shell harness (same setup as root_swipe_switcher_test): the real
/// `createPixivRouter` wires `_page`, so routes pushed through it carry the
/// resolved platform duration. Feed pages keep a skeleton shimmer ticking,
/// so callers pump fixed durations rather than pumpAndSettle.
Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  bool reduceMotion = false,
  AnimationSpeed? speed,
  PageTransitionStyle? transitionStyle,
  String location = '/recommended',
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  setViewSize(tester, const Size(390, 844));
  final router = pixivRouter(location);
  Widget app = localizedRouterApp(router, locale: const Locale('en', 'US'));
  if (reduceMotion || speed != null || transitionStyle != null) {
    app = MotionScope(
      reduce: reduceMotion,
      speed: speed ?? AnimationSpeed.normal,
      transitionStyle: transitionStyle ?? PageTransitionStyle.system,
      child: app,
    );
  }
  await tester.pumpWidget(
    ProviderScope(overrides: [...signedInAccountOverrides()], child: app),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return router;
}

ModalRoute<dynamic> _routeOf(WidgetTester tester, Finder finder) =>
    ModalRoute.of(tester.element(finder))!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a page reading its route animation is not rebuilt as its route is covered, uncovered or popped',
    (tester) async {
      final builds = <Animation<double>?>[];
      final route = await _pushSecondPage(
        tester,
        second: _RouteAnimationProbe(builds),
      );
      expect(builds.single, same(route.animation));

      // Each step flips the route's isCurrent, which rebuilt every
      // ModalRoute.of reader: the leaving detail page and both neighbours.
      final navigator = route.navigator!;
      unawaited(
        navigator.push(
          const FuncPage<void>(
            child: Text('page c'),
          ).createRoute(tester.element(find.text('page b'))),
        ),
      );
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(builds, hasLength(1));
    },
  );

  testWidgets('inside a nested Navigator the route animation is the inner '
      "route's, not the enclosing page's", (tester) async {
    final builds = <Animation<double>?>[];
    final outer = await _pushSecondPage(
      tester,
      second: Navigator(
        onGenerateRoute: (_) => PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => _RouteAnimationProbe(builds),
        ),
      ),
    );
    final inner = ModalRoute.of(tester.element(find.text('page b')))!;
    expect(inner, isNot(same(outer)));
    expect(builds.single, same(inner.animation));
  });

  testWidgets('a throwing back-gesture commit releases the Navigator', (
    tester,
  ) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Navigator(
          key: key,
          onGenerateRoute: (_) =>
              MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink()),
        ),
      ),
    );
    final navigator = key.currentState!;
    navigator.didStartUserGesture();
    expect(navigator.userGestureInProgress, isTrue);

    expect(
      () => commitBackGestureGuarded(navigator, () => throw StateError('pop')),
      throwsStateError,
    );
    expect(navigator.userGestureInProgress, isFalse);
  });

  testWidgets('a successful back-gesture commit is not stopped twice', (
    tester,
  ) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Navigator(
          key: key,
          onGenerateRoute: (_) =>
              MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink()),
        ),
      ),
    );
    final navigator = key.currentState!;
    var committed = false;
    commitBackGestureGuarded(navigator, () {
      committed = true;
    });
    expect(committed, isTrue);
    expect(navigator.userGestureInProgress, isFalse);
  });

  testWidgets('the back gesture drives the route and commits', (tester) async {
    final route = await _pushSecondPage(tester);

    await _startBackGesture();
    await tester.pump();
    expect(_sharedElementTransition(), findsWidgets);
    expect(route.animation!.value, 1.0);

    await _dragBackGesture(0.35);
    await tester.pump();
    expect(route.animation!.value, moreOrLessEquals(0.65));

    await _sendBackGestureMethod('commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsNothing);
    expect(find.text('page a'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'a button back pops through FadeForwards, not the gesture transition',
    (tester) async {
      final route = await _pushSecondPage(tester);

      Navigator.of(tester.element(find.text('page b'))).pop();
      await tester.pump();
      // FadeForwards animates the route out over the builder's 800ms
      // window; the shared-element gesture transition never enters the
      // tree.
      expect(_sharedElementTransition(), findsNothing);
      expect(route.animation!.isAnimating, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      expect(route.animation!.isAnimating, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('page a'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final style in PageTransitionStyle.values) {
    testWidgets('a shared-element page fades over a still page in either '
        'style while its Hero flies (${style.name})', (tester) async {
      late BuildContext rootContext;
      late PageRoute<void> pushed;
      var stillTaps = 0;
      PageRoute<void> page(Widget child, {bool sharedElement = false}) =>
          FuncPage<void>(
                transitionDuration: const Duration(milliseconds: 400),
                reverseTransitionDuration: const Duration(milliseconds: 400),
                transitionStyle: style,
                sharedElement: sharedElement,
                child: child,
              ).createRoute(rootContext)
              as PageRoute<void>;
      Widget hero(String label, Offset at, {double height = 50}) => Stack(
        children: [
          Positioned(
            left: at.dx,
            top: at.dy,
            child: Hero(
              tag: 'art',
              transitionOnUserGestures: true,
              flightShuttleBuilder: illustHeroFlightShuttleBuilder,
              child: SizedBox(width: 50, height: height, child: Text(label)),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              rootContext = context;
              return Navigator(
                observers: [HeroController()],
                onGenerateRoute: (_) => page(
                  Builder(
                    builder: (context) => Stack(
                      children: [
                        GestureDetector(
                          onTap: () {
                            pushed = page(
                              hero(
                                'detail',
                                const Offset(300, 500),
                                height: 100,
                              ),
                              sharedElement: true,
                            );
                            Navigator.of(context).push(pushed);
                          },
                          child: hero('card', Offset.zero),
                        ),
                        Positioned(
                          left: 0,
                          top: 200,
                          child: GestureDetector(
                            onTap: () => stillTaps++,
                            child: const Text('still'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      const still = Offset(0, 200);
      double pageOpacity() => tester
          .widgetList<FadeTransition>(
            find.ancestor(
              of: find.byType(Hero).last,
              matching: find.byType(FadeTransition),
            ),
          )
          .last
          .opacity
          .value;
      // Mid-flight the page below holds still, and the fading page has a
      // hole where its image sits, so the page below shows there rather
      // than a blank; the rest of the stage still paints. Leaving, the page
      // has mostly faded halfway through, not waiting for the image.
      void expectFlyingHome() {
        expect(pageOpacity(), lessThan(0.5));
        // The shuttle flies the leaving page's image.
        final flying = tester.getTopLeft(find.text('detail'));
        expect(flying.dx, inExclusiveRange(0, 300));
        expect(flying.dy, inExclusiveRange(0, 500));
        expect(tester.getTopLeft(find.text('still')), still);
        final stage = tester.getRect(find.byType(Hero).last);
        expect(_liftedHoleAt(tester, stage.center), isTrue);
        expect(
          _liftedHoleAt(tester, stage.topCenter.translate(0, -1)),
          isFalse,
        );
      }

      await tester.tap(find.text('card'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getTopLeft(find.text('still')), still);
      expect(pageOpacity(), greaterThan(0.5));
      // Only a landed page has its image lifted off.
      expect(_liftedHoleAt(tester, const Offset(325, 550)), isNull);
      await tester.pumpAndSettle();

      // The back gesture scrubs the fade; the image follows the finger
      // home and returns on a cancel.
      await _startBackGesture();
      await _dragBackGesture(0.5);
      await tester.pump();
      expect(pushed.animation!.value, inExclusiveRange(0, 1));
      expectFlyingHome();
      await _sendBackGestureMethod('cancelBackGesture');
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('detail')), const Offset(300, 500));

      // Back fades the page out while the image flies home.
      Navigator.of(tester.element(find.text('detail'))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expectFlyingHome();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('card')), Offset.zero);
      expect(find.text('detail'), findsNothing);

      // A committed gesture hands the page below the touch at once, while
      // the image is still on its way.
      await tester.tap(find.text('card'));
      await tester.pumpAndSettle();
      await _startBackGesture();
      await _dragBackGesture(0.3);
      await tester.pump();
      await _sendBackGestureMethod('commitBackGesture');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(pushed.animation!.isAnimating, isTrue);
      await tester.tap(find.text('still'));
      expect(stillTaps, 1);
      await tester.pumpAndSettle();
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('the scoped tier still collapses under reduced motion', (
    tester,
  ) async {
    final router = await _pumpHome(
      tester,
      reduceMotion: true,
      speed: AnimationSpeed.slow,
    );
    unawaited(router.push('/recommended/history'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final route = _routeOf(tester, find.byType(HistoryPage));
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('the entering page stays live while a transition runs', (
    tester,
  ) async {
    final probe = ValueNotifier<double>(0);
    addTearDown(probe.dispose);
    final pushed = await _pushSecondPage(
      tester,
      second: _TickerProbe(seen: probe),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(pushed.animation!.isAnimating, isTrue);
    // No disabled TickerMode wraps the pushed page mid-transition, and its
    // tickers keep running: icons, bookmark state and image fades update
    // live instead of jumping when the transition lands.
    expect(
      find.byWidgetPredicate(
        (widget) => widget is TickerMode && !widget.enabled,
      ),
      findsNothing,
    );
    expect(probe.value, greaterThan(0));
    await tester.pumpAndSettle();
    expect(probe.value, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('only the visible branch answers the back gesture', (
    tester,
  ) async {
    final router = await _pumpHome(tester);
    unawaited(router.push('/recommended/history'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HistoryPage), findsOneWidget);
    final branch0Route = _routeOf(tester, find.byType(HistoryPage));

    router.go('/ranking');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(HistoryPage), findsNothing);

    unawaited(router.push('/ranking/history'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final branch1Route = _routeOf(tester, find.byType(HistoryPage));
    // The covered branch's identical page is still mounted offstage —
    // a visible marker that it did NOT take the gesture below.
    expect(find.byType(HistoryPage, skipOffstage: false), findsNWidgets(2));

    await _startBackGesture();
    await tester.pump();
    await _dragBackGesture(0.35);
    await tester.pump();
    expect(branch1Route.animation!.value, moreOrLessEquals(0.65));
    expect(branch0Route.animation!.value, 1.0);

    await _sendBackGestureMethod('commitBackGesture');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // The visible branch popped its pushed route; the parked branch's
    // identical page survives offstage.
    expect(find.byType(HistoryPage), findsNothing);
    expect(find.byType(HistoryPage, skipOffstage: false), findsOneWidget);

    // goBranch keeps the branch stack — go() would re-match the root
    // and drop the pushed page.
    tester
        .widget<HomeBranchStack>(find.byType(HomeBranchStack))
        .shell
        .goBranch(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(HistoryPage), findsOneWidget);
    expect(branch0Route.isActive, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a root-level page owns the gesture over the whole shell', (
    tester,
  ) async {
    final router = await _pumpHome(tester, location: '/ranking');
    unawaited(router.push('/ranking/history'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final historyRoute = _routeOf(tester, find.byType(HistoryPage));

    unawaited(router.push('/me'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MePage), findsOneWidget);
    final meRoute = _routeOf(tester, find.byType(MePage));

    await _startBackGesture();
    await tester.pump();
    await _dragBackGesture(0.35);
    await tester.pump();
    expect(meRoute.animation!.value, moreOrLessEquals(0.65));
    expect(historyRoute.animation!.value, 1.0);

    await _sendBackGestureMethod('commitBackGesture');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MePage), findsNothing);
    expect(find.byType(HistoryPage), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'a dirty profile editor ignores the gesture but confirms on back',
    (tester) async {
      installMemoryPreferences();
      const owner = ProfileEditOwner(accountId: 'account-a');
      const user = UserEntity(
        id: 42,
        name: 'old name',
        account: 'old-account',
        comment: 'old bio',
        webpage: 'https://example.com',
        profileImageUrl: 'https://i.pximg.net/avatar.png',
        backgroundImageUrl: 'https://i.pximg.net/background.png',
        hasDetail: true,
      );
      final session = ProfileEditSession(
        repository: _StubProfileEditRepository(user),
        owner: owner,
        readOwner: () => owner,
        initialUser: user,
        onConfirmed: (_) async {},
      );
      final container = ProviderContainer.test(
        overrides: [
          profileEditControllerProvider.overrideWith2(
            (arguments) => ProfileEditController(arguments),
          ),
        ],
      );
      await container
          .read(profileEditControllerProvider(session).notifier)
          .load();

      late BuildContext rootContext;
      await tester.pumpWidget(
        localizedApp(
          container: container,
          locale: const Locale('en', 'US'),
          home: Builder(
            builder: (context) {
              rootContext = context;
              return Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    FuncPage<void>(
                          child: ProfileEditPage(userId: 42, session: session),
                        ).createRoute(rootContext)
                        as PageRoute<void>,
                  ),
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('open'));
      // Fixed pumps — the avatar's image placeholder keeps a shimmer
      // ticking, so pumpAndSettle never returns.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ProfileEditPage), findsOneWidget);
      final editRoute = _routeOf(tester, find.byType(ProfileEditPage));

      // The editor builds material_ui's TextFormField — a different class
      // from flutter/material's — so match by name.
      final fields = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == 'TextFormField',
      );
      await tester.enterText(fields.first, 'changed');
      await tester.pump();

      // PopScope(canPop: false) marks the route doNotPop, so the gesture
      // never starts: no predictive-back transition, no animation.
      await _startBackGesture();
      await tester.pump();
      expect(_sharedElementTransition(), findsNothing);
      expect(editRoute.animation!.value, 1.0);
      expect(find.byType(ProfileEditPage), findsOneWidget);

      // The system back button still routes through PopScope and shows
      // the discard confirmation.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard unsaved changes?'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

/// Minimal repository — the editor only needs capabilities plus the saved
/// draft to reach its editable state.
class _StubProfileEditRepository implements ProfileEditRepository {
  _StubProfileEditRepository(this.user);

  final UserEntity user;

  @override
  Future<ProfileCapabilities> loadCapabilities({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) async => ProfileCapabilities(
    editableFields: {
      ProfileField.displayName,
      ProfileField.comment,
      ProfileField.webpage,
    },
    channel: ProfileEditChannel.appApi,
  );

  @override
  Future<UserEntity> loadDraft({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) async => user;

  @override
  Future<ProfileEditOutcome> submit(
    ProfileSubmitRequest request, {
    CancelToken? cancelToken,
  }) async => ProfileEditConfirmed(user);
}

/// A ticker probe for route-transition tests: drives an animation from the
/// pushed page and records progress, so a frozen ticker reads 0 mid-flight.
class _TickerProbe extends StatefulWidget {
  const _TickerProbe({required this.seen});

  final ValueNotifier<double> seen;

  @override
  State<_TickerProbe> createState() => _TickerProbeState();
}

class _TickerProbeState extends State<_TickerProbe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..addListener(() => widget.seen.value = _controller.value);

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('page b');
}

/// Records the route animation it sees on every build.
class _RouteAnimationProbe extends StatefulWidget {
  const _RouteAnimationProbe(this.builds);

  final List<Animation<double>?> builds;

  @override
  State<_RouteAnimationProbe> createState() => _RouteAnimationProbeState();
}

class _RouteAnimationProbeState extends State<_RouteAnimationProbe> {
  Animation<double>? _animation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animation = RouteAnimationScope.of(context);
  }

  @override
  Widget build(BuildContext context) {
    widget.builds.add(_animation);
    return const Text('page b');
  }
}
