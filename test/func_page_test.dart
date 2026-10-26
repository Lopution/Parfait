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
import 'package:parfait/app/navigation/home_shell_metrics.dart';
import 'package:parfait/app/navigation/route_animation.dart';
import 'package:parfait/app/widgets/home_branch_stack.dart';
import 'package:parfait/core/settings/app_settings.dart' show AnimationSpeed;
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

/// Android's back gesture, starting at the left edge.
Future<void> _startBackGesture() => _sendBackGestureMethod('startBackGesture', {
  'touchOffset': <double>[5.0, 300.0],
  'progress': 0.0,
  'swipeEdge': 0,
});

/// The back swipe, 100 px in, at [progress].
Future<void> _dragBackGesture(double progress) =>
    _sendBackGestureMethod('updateBackGestureProgress', {
      'touchOffset': <double>[100.0, 300.0],
      'progress': progress,
      'swipeEdge': 0,
    });

/// Pumps a bare Navigator whose initial route is a [FuncPage]; the page's
/// button pushes a second FuncPage showing [second] and hands the route back
/// through the return value, settled unless [settle] is false.
Future<PageRoute<void>> _pushSecondPage(
  WidgetTester tester, {
  Duration duration = const Duration(milliseconds: 800),
  Widget? home,
  Widget second = const Text('page b'),
  bool settle = true,
}) async {
  late PageRoute<void> pushed;
  late BuildContext rootContext;
  PageRoute<void> page(Widget child) =>
      FuncPage<void>(
            transitionDuration: duration,
            reverseTransitionDuration: duration,
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
  String location = '/recommended',
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  setViewSize(tester, const Size(390, 844));
  final router = pixivRouter(location);
  Widget app = localizedRouterApp(router, locale: const Locale('en', 'US'));
  if (reduceMotion || speed != null) {
    app = MotionScope(
      reduce: reduceMotion,
      speed: speed ?? AnimationSpeed.normal,
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
      // The controller behind the route's proxy, which reads complete for
      // the frame a Hero measures the opening page in.
      expect(builds.single, same((route.animation! as ProxyAnimation).parent));

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

  for (final covered in [true, false]) {
    testWidgets(
      'a page ${covered ? 'covered by a route' : 'in a hidden branch'} keeps '
      'the media and shell chrome it saw until it shows again',
      (tester) async {
        setViewSize(tester, const Size(400, 800));
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        final seen = <(MediaQueryData, double)>[];
        final hidden = ValueNotifier(false);
        addTearDown(hidden.dispose);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              // Like the shell: the bar's extent follows the bottom inset.
              builder: (context) => HomeShellChrome(
                bottomBarExtent: 80 + MediaQuery.paddingOf(context).bottom,
                bottomBarVisibleExtent: const AlwaysStoppedAnimation(0),
                bottomBarVisibility: kAlwaysCompleteAnimation,
                onBranchRootScroll: (_) => false,
                child: ValueListenableBuilder(
                  valueListenable: hidden,
                  builder: (_, off, child) =>
                      TickerMode(enabled: !off, child: child!),
                  child: Navigator(
                    key: navigator,
                    onGenerateRoute: (_) => FuncPage<void>(
                      child: Builder(
                        builder: (context) {
                          seen.add((
                            MediaQuery.of(context),
                            HomeShellChrome.of(context).bottomBarExtent,
                          ));
                          return const SizedBox.expand();
                        },
                      ),
                    ).createRoute(context),
                  ),
                ),
              ),
            ),
          ),
        );
        if (covered) {
          unawaited(
            navigator.currentState!.push(
              const FuncPage<void>(
                child: SizedBox.expand(),
              ).createRoute(navigator.currentContext!),
            ),
          );
          await tester.pumpAndSettle();
        } else {
          hidden.value = true;
          await tester.pump();
        }
        final builds = seen.length;

        tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
        await tester.pump();
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pump();
        tester.view.physicalSize = const Size(800, 400);
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        await tester.pump();
        expect(seen, hasLength(builds));

        if (covered) {
          navigator.currentState!.pop();
          await tester.pump();
        } else {
          hidden.value = false;
          await tester.pump();
        }
        final live = MediaQuery.of(navigator.currentContext!);
        expect(live.size, const Size(800, 400));
        expect(seen.last.$1, live);
        expect(seen.last.$2, 80 + live.padding.bottom);
        await tester.pumpAndSettle();
      },
    );
  }

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

  testWidgets('a page slides in from the trailing edge over the page below', (
    tester,
  ) async {
    final route = await _pushSecondPage(tester, settle: false);
    await tester.pump(const Duration(milliseconds: 400));
    final width = tester.getSize(find.byType(Navigator)).width;
    final entering = tester.getTopLeft(find.text('page b')).dx;
    final below = tester.getTopLeft(find.text('page a')).dx;
    await tester.pumpAndSettle();

    route.navigator!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final leaving = tester.getTopLeft(find.text('page b')).dx;
    await tester.pumpAndSettle();
    expect([entering, leaving], everyElement(inExclusiveRange(0, width)));
    expect(below, lessThan(tester.getTopLeft(find.text('page a')).dx));
  });

  testWidgets(
    'back mid-push turns the slide where it is; the page below answers',
    (tester) async {
      // The page below fills its button, so a tap anywhere reaches it.
      final route = await _pushSecondPage(
        tester,
        home: const SizedBox.expand(child: Text('page a')),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 320));
      final navigator = route.navigator!;
      final pageB = find.text('page b');
      double x() => tester.getTopLeft(pageB).dx;
      var last = x();
      navigator.pop();
      await tester.pump();
      expect(x(), last, reason: 'turns without a jump');
      final steps = <double>[];
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (pageB.evaluate().isEmpty) break;
        steps.add(x() - last);
        last = x();
      }
      // The rest of the way on the pop curve: off fast, easing out at the
      // edge. The push curve played backwards crept off and left at speed.
      expect(steps, everyElement(greaterThanOrEqualTo(0)));
      expect(steps.first, greaterThan(4 * steps.last));

      // Leaving, the page takes no touch: a tap where it still is lands on
      // the page below, which opens a page again.
      await tester.tap(find.text('page a'));
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(700, 300));
      await tester.pump();
      expect(find.text('page b'), findsNWidgets(2));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a shared-element page covers a still page, then shows its '
      'content while its Hero flies; leaving runs the other way', (
    tester,
  ) async {
    late BuildContext rootContext;
    late PageRoute<void> pushed;
    var stillTaps = 0;
    PageRoute<void> page(Widget child, {bool sharedElement = false}) =>
        FuncPage<void>(
              transitionDuration: const Duration(milliseconds: 400),
              reverseTransitionDuration: const Duration(milliseconds: 400),
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
                            hero('detail', const Offset(300, 500), height: 100),
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
    double layer(Type child) => tester
        .widget<FadeTransition>(
          find.byWidgetPredicate(
            (widget) =>
                widget is FadeTransition && widget.child.runtimeType == child,
          ),
        )
        .opacity
        .value;
    double backdrop() => layer(ColoredBox);
    double content() => layer(HeroLiftHole);
    Future<void> at(int milliseconds) async {
      await tester.pump();
      await tester.pump(Duration(milliseconds: milliseconds));
    }

    // Opening: the background covers the still page first, the content
    // fades in on it after. Until then the content paints at the faintest
    // alpha, unseen, so its first draw is not mid-flight.
    await tester.tap(find.text('card'));
    await at(60);
    expect(backdrop(), inExclusiveRange(0, 1));
    expect(Color.getAlphaFromOpacity(content()), 1);
    await tester.pump(const Duration(milliseconds: 140));
    expect(backdrop(), 1);
    expect(content(), inExclusiveRange(0, 1));
    expect(tester.getTopLeft(find.text('still')), still);
    // Only a landed page has its image lifted off.
    expect(_liftedHoleAt(tester, const Offset(325, 550)), isNull);
    await tester.pumpAndSettle();
    expect([backdrop(), content()], [1, 1]);

    // Back: the content goes first, then the background; the image flies
    // home out of a hole in the page and the page below takes the touch.
    Navigator.of(tester.element(find.text('detail'))).pop();
    await at(80);
    expect(backdrop(), 1);
    expect(content(), inExclusiveRange(0, 1));
    final stage = tester.getRect(find.byType(Hero).last);
    expect(_liftedHoleAt(tester, stage.center), isTrue);
    expect(_liftedHoleAt(tester, stage.topCenter.translate(0, -1)), isFalse);
    await tester.pump(const Duration(milliseconds: 160));
    expect(content(), 0);
    expect(backdrop(), inExclusiveRange(0, 1));
    final flying = tester.getTopLeft(find.text('detail'));
    expect(flying.dx, inExclusiveRange(0, 300));
    expect(flying.dy, inExclusiveRange(0, 500));
    expect(tester.getTopLeft(find.text('still')), still);
    await tester.tap(find.text('still'));
    expect(stillTaps, 1);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('card')), Offset.zero);
    expect(find.text('detail'), findsNothing);

    // Back cutting an opening short leaves each layer from where it got
    // to, not from nothing in one frame.
    await tester.tap(find.text('card'));
    await at(200);
    final opened = content();
    expect(opened, inExclusiveRange(0, 1));
    Navigator.of(tester.element(find.text('still'))).pop();
    await at(16);
    expect(content(), inExclusiveRange(opened - 0.15, opened + 1e-6));
    expect(backdrop(), greaterThan(0.9));
    await tester.pumpAndSettle();
  });

  testWidgets('two backs in a row leave the page under the shared-element '
      'page still', (tester) async {
    // Feed → detail (shared element) → author page, then back twice
    // while the author page is still leaving: the Navigator announces the
    // feed to the leaving author page, which must not make the feed slide
    // in under the landing image.
    late BuildContext rootContext;
    PageRoute<void> page(String label, {bool sharedElement = false}) =>
        FuncPage<void>(
              transitionDuration: const Duration(milliseconds: 400),
              reverseTransitionDuration: const Duration(milliseconds: 400),
              sharedElement: sharedElement,
              child: Text(label),
            ).createRoute(rootContext)
            as PageRoute<void>;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            rootContext = context;
            return Navigator(onGenerateRoute: (_) => page('feed'));
          },
        ),
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(page('detail', sharedElement: true));
    await tester.pumpAndSettle();
    navigator.push(page('author'));
    await tester.pumpAndSettle();

    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    navigator.pop();
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getTopLeft(find.text('feed')), Offset.zero);
    }
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsNothing);

    // A shared-element page removed without a pop lets the feed go.
    final detail = page('detail', sharedElement: true);
    navigator.push(detail);
    await tester.pumpAndSettle();
    navigator.removeRoute(detail);
    await tester.pump();
    final feed = ModalRoute.of(tester.element(find.text('feed')))!;
    expect(underSharedElement(feed), isFalse);
  });

  testWidgets('the viewer stage fades whole, with no background', (
    tester,
  ) async {
    late BuildContext rootContext;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            rootContext = context;
            return Navigator(
              onGenerateRoute: (_) => FuncPage<void>(
                child: Builder(
                  builder: (context) => GestureDetector(
                    onTap: () => Navigator.of(context).push(
                      FuncPage<void>(
                        transitionDuration: const Duration(milliseconds: 400),
                        sharedElement: true,
                        sharedElementBackdrop: false,
                        child: const Text('stage'),
                      ).createRoute(rootContext),
                    ),
                    child: const Text('detail'),
                  ),
                ),
              ).createRoute(rootContext),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('detail'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('stage'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, inExclusiveRange(0, 1));
    expect(
      find.byWidgetPredicate(
        (widget) => widget is FadeTransition && widget.child is ColoredBox,
      ),
      findsNothing,
    );
    await tester.pumpAndSettle();
  });

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
    await _dragBackGesture(0.35);
    await tester.pump();
    expect(branch1Route.animation!.value, 1.0);
    expect(branch0Route.animation!.value, 1.0);
    await _sendBackGestureMethod('cancelBackGesture');
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HistoryPage), findsOneWidget);

    // No route takes the gesture, so the framework pops on its commit as
    // on the back button.
    await _startBackGesture();
    await _dragBackGesture(0.35);
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
    await _dragBackGesture(0.35);
    await tester.pump();
    expect(meRoute.animation!.value, 1.0);
    expect(historyRoute.animation!.value, 1.0);

    await _sendBackGestureMethod('commitBackGesture');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MePage), findsNothing);
    expect(find.byType(HistoryPage), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'a dirty profile editor confirms on the back gesture instead of popping',
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

      // The gesture's commit is the back button: PopScope(canPop: false)
      // keeps the page and asks.
      await _startBackGesture();
      await _dragBackGesture(0.5);
      await tester.pump();
      expect(editRoute.animation!.value, 1.0);
      await _sendBackGestureMethod('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      expect(editRoute.isActive, isTrue);
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
