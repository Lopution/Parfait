import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/navigation/func_page.dart';
import 'package:parfait/app/navigation/home_shell_metrics.dart';
import 'package:parfait/app/widgets/home_branch_stack.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/profile/profile_edit_controller.dart';
import 'package:parfait/core/profile/profile_edit_models.dart';
import 'package:parfait/core/profile/profile_edit_repository.dart';
import 'package:parfait/core/settings/app_settings.dart' show AnimationSpeed;
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/features/history/history_page.dart';
import 'package:parfait/features/profile/profile_edit_page.dart';
import 'package:parfait/features/profile/user_page.dart';

import 'helpers/api_responses.dart';
import 'helpers/fake_account.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/profile_world.dart';
import 'helpers/view_size.dart';

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
/// button pushes a second FuncPage showing [second] and hands the route back.
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
    MotionScope(
      reduce: false,
      speed: AnimationSpeed.normal,
      child: Directionality(
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
    ),
  );
  await tester.tap(find.text('page a'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  expect(find.text('page b'), findsOneWidget);
  return pushed;
}

/// Full-shell harness wired through `createPixivRouter`.
Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  String location = '/recommended',
}) async {
  setViewSize(tester, const Size(390, 844));
  final router = pixivRouter(location);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [...await signedInAccountOverrides()],
      child: localizedRouterApp(router, locale: const Locale('en', 'US')),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return router;
}

ModalRoute<dynamic> _routeOf(WidgetTester tester, Finder finder) =>
    ModalRoute.of(tester.element(finder))!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

    await _startBackGesture();
    await _dragBackGesture(0.35);
    await _sendBackGestureMethod('commitBackGesture');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HistoryPage), findsNothing);
    expect(find.byType(HistoryPage, skipOffstage: false), findsOneWidget);

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
      answerWebProfileSession();
      final api = await signedInApiContainer(
        PixivApi(UserApi(detail: user).routes).client,
        account: const Account(id: '42', userId: 42, name: 'tester'),
      );
      final session = ProfileEditSession(
        repository: api.read(profileEditRepositoryProvider),
        owner: owner,
        readOwner: () => owner,
        userId: user.id,
        onConfirmed: (_) async {},
      );
      final container = ProviderContainer.test(
        overrides: [
          profileEditControllerProvider.overrideWith2(
            (arguments) => ProfileEditController(arguments),
          ),
        ],
      );
      final editor = profileEditControllerProvider(session);
      container.listen(editor, (_, _) {});
      await container.read(editor.notifier).load();

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
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ProfileEditPage), findsOneWidget);
      final editRoute = _routeOf(tester, find.byType(ProfileEditPage));

      final fields = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == 'TextFormField',
      );
      await tester.enterText(fields.first, 'changed');
      await tester.pump();

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

  testWidgets(
    'iOS edge-swipe pops active visible route from left 24dp edge without stealing pager drags',
    (tester) async {
      setViewSize(tester, const Size(400, 800));
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final pageController = PageController();
      addTearDown(pageController.dispose);
      final pushed = await _pushSecondPage(
        tester,
        second: Stack(
          children: [
            Positioned.fill(
              child: PageView(
                controller: pageController,
                children: const [
                  Center(child: Text('slide 0')),
                  Center(child: Text('slide 1')),
                ],
              ),
            ),
            const Align(alignment: Alignment.topCenter, child: Text('page b')),
          ],
        ),
      );

      await tester.drag(find.byType(PageView), const Offset(-260, 0));
      await tester.pumpAndSettle();
      expect(pageController.page, 1.0);
      expect(pushed.isActive, isTrue);

      await tester.dragFrom(const Offset(100, 300), const Offset(260, 0));
      await tester.pumpAndSettle();
      expect(pageController.page, 0.0);
      expect(pushed.isActive, isTrue);

      final edgeDrag = await tester.startGesture(const Offset(12, 300));
      await edgeDrag.moveBy(const Offset(30, 0));
      await edgeDrag.moveBy(const Offset(90, 0));
      await tester.pump();
      expect(pushed.animation!.value, lessThan(1.0));

      await edgeDrag.moveBy(const Offset(140, 0));
      await edgeDrag.up();
      await tester.pumpAndSettle();
      expect(pushed.isActive, isFalse);
      expect(find.text('page a'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS edge-swipe respects PopScope dirty-form guard and stays off on offstage branches',
    (tester) async {
      setViewSize(tester, const Size(400, 800));
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final guardPushed = await _pushSecondPage(
        tester,
        second: const PopScope<void>(
          canPop: false,
          child: SizedBox.expand(child: Center(child: Text('page b'))),
        ),
      );
      await tester.dragFrom(const Offset(12, 300), const Offset(260, 0));
      await tester.pumpAndSettle();
      expect(guardPushed.animation!.value, 1.0);
      expect(guardPushed.isActive, isTrue);
      expect(find.text('page b'), findsOneWidget);

      final router = await _pumpHome(tester);
      unawaited(router.push('/recommended/history'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final branch0Route = _routeOf(tester, find.byType(HistoryPage));

      router.go('/ranking');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byType(HistoryPage), findsNothing);
      expect(find.byType(HistoryPage, skipOffstage: false), findsOneWidget);

      await tester.dragFrom(const Offset(12, 300), const Offset(260, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(branch0Route.isActive, isTrue);

      tester
          .widget<HomeBranchStack>(find.byType(HomeBranchStack))
          .shell
          .goBranch(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byType(HistoryPage), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
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

  testWidgets('a leaving page mid-pop lets taps reach the page below', (
    tester,
  ) async {
    final route = await _pushSecondPage(
      tester,
      home: const SizedBox.expand(child: Text('page a')),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 320));
    final navigator = route.navigator!;
    navigator.pop();
    await tester.pump(const Duration(milliseconds: 50));

    // Leaving page is still on screen during pop, yet taps must reach page a.
    expect(find.text('page b'), findsOneWidget);
    await tester.tap(find.text('page a'));
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsOneWidget);
  });
}
