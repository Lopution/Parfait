import 'dart:async';

import 'package:flutter/material.dart'
    hide PredictiveBackPageTransitionsBuilder;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart'
    show PredictiveBackPageTransitionsBuilder;
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:pixiv_func/app/motion/motion_tokens.dart';
import 'package:pixiv_func/app/motion/page_transitions.dart';
import 'package:pixiv_func/app/navigation/func_page.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/app/widgets/branch_slide_stack.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/profile/profile_edit_controller.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/profile/profile_edit_models.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/features/history/history_page.dart';
import 'package:pixiv_func/features/profile/profile_edit_page.dart';
import 'package:pixiv_func/features/profile/user_page.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

const _account = Account(id: '100', userId: 100, name: 'tester');

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

Finder _sharedElementTransition() => find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString().contains(
    'PredictiveBackSharedElementPageTransition',
  ),
);

/// Pumps a bare Navigator whose initial route is a [FuncPage]; the page's
/// button pushes a second FuncPage and hands the route back through the
/// return value.
Future<PageRoute<void>> _pushSecondPage(
  WidgetTester tester, {
  Duration duration = const Duration(milliseconds: 800),
  Widget? home,
}) async {
  late final PageRoute<void> pushed;
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
                    pushed = page(const Text('page b'));
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
  String location = '/recommended',
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = createPixivRouter(initialLocation: location);
  addTearDown(router.dispose);
  Widget app = MaterialApp.router(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en', 'US'),
    routerConfig: router,
  );
  if (reduceMotion) {
    app = MotionScope(reduce: true, child: app);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...accountProviderOverrides(
          credentialStore: FakeCredentialStore(
            values: const {
              '100': Credential(accessToken: 'a-100', refreshToken: 'r-100'),
            },
          ),
          metadataRepository: FakeAccountMetadataRepository(
            accounts: const [_account],
            currentId: '100',
          ),
        ),
      ],
      child: app,
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

  testWidgets('the back gesture drives the route and commits', (tester) async {
    final route = await _pushSecondPage(tester);

    await _sendBackGestureMethod('startBackGesture', {
      'touchOffset': <double>[5.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await tester.pump();
    expect(_sharedElementTransition(), findsWidgets);
    expect(route.animation!.value, 1.0);

    await _sendBackGestureMethod('updateBackGestureProgress', {
      'touchOffset': <double>[100.0, 300.0],
      'progress': 0.35,
      'swipeEdge': 0,
    });
    await tester.pump();
    expect(route.animation!.value, moreOrLessEquals(0.65));

    await _sendBackGestureMethod('commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsNothing);
    expect(find.text('page a'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('cancelling the gesture restores the route', (tester) async {
    final route = await _pushSecondPage(tester);

    await _sendBackGestureMethod('startBackGesture', {
      'touchOffset': <double>[5.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await tester.pump();
    await _sendBackGestureMethod('updateBackGestureProgress', {
      'touchOffset': <double>[100.0, 300.0],
      'progress': 0.3,
      'swipeEdge': 0,
    });
    await tester.pump();
    expect(route.animation!.value, lessThan(1.0));

    await _sendBackGestureMethod('cancelBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsOneWidget);
    expect(route.animation!.value, 1.0);
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

  testWidgets('routes pushed through _page carry the builder duration', (
    tester,
  ) async {
    final router = await _pumpHome(tester);
    unawaited(router.push('/recommended/history'));
    // The 800ms route transition plus the feed's shimmer settle window —
    // pump a fixed span, the shimmer never lets pumpAndSettle return.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HistoryPage), findsOneWidget);
    final route = _routeOf(tester, find.byType(HistoryPage));
    expect(
      route.transitionDuration,
      const PredictiveBackPageTransitionsBuilder().transitionDuration,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('windows keeps the FuncRouteTransition slide', (tester) async {
    await _pushSecondPage(tester, duration: MotionTokens.pageTransition);
    expect(find.byType(FuncRouteTransition), findsWidgets);
    expect(_sharedElementTransition(), findsNothing);

    // The gesture channel is android-only; a fake event must be ignored.
    await _sendBackGestureMethod('startBackGesture', {
      'touchOffset': <double>[5.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await tester.pump();
    expect(find.text('page b'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('reduced motion collapses the route duration to zero', (
    tester,
  ) async {
    final router = await _pumpHome(tester, reduceMotion: true);
    unawaited(router.push('/recommended/history'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final route = _routeOf(tester, find.byType(HistoryPage));
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('TickerMode freezes the page while a transition runs', (
    tester,
  ) async {
    late final PageRoute<void> pushed;
    late BuildContext rootContext;
    PageRoute<void> page(Widget child) =>
        FuncPage<void>(
              transitionDuration: const Duration(milliseconds: 800),
              reverseTransitionDuration: const Duration(milliseconds: 800),
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
                      pushed = page(const Text('page b'));
                      Navigator.of(context).push(pushed);
                    },
                    child: const Text('page a'),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('page a'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(pushed.animation!.isAnimating, isTrue);
    // The guard sits above the route content: a disabled TickerMode must
    // wrap the pushed page's subtree.
    expect(
      find.byWidgetPredicate(
        (widget) => widget is TickerMode && !widget.enabled,
      ),
      findsWidgets,
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is TickerMode && !widget.enabled,
      ),
      findsNothing,
    );
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

    await _sendBackGestureMethod('startBackGesture', {
      'touchOffset': <double>[5.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await tester.pump();
    await _sendBackGestureMethod('updateBackGestureProgress', {
      'touchOffset': <double>[100.0, 300.0],
      'progress': 0.35,
      'swipeEdge': 0,
    });
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
        .widget<BranchSlideStack>(find.byType(BranchSlideStack))
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

    await _sendBackGestureMethod('startBackGesture', {
      'touchOffset': <double>[5.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await tester.pump();
    await _sendBackGestureMethod('updateBackGestureProgress', {
      'touchOffset': <double>[100.0, 300.0],
      'progress': 0.35,
      'swipeEdge': 0,
    });
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
      final container = ProviderContainer(
        overrides: [
          profileEditControllerProvider.overrideWith2(
            (arguments) => ProfileEditController(arguments),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(profileEditControllerProvider(session).notifier)
          .load();

      late BuildContext rootContext;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en', 'US'),
            home: Builder(
              builder: (context) {
                rootContext = context;
                return Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      FuncPage<void>(
                            child: ProfileEditPage(
                              userId: 42,
                              session: session,
                            ),
                          ).createRoute(rootContext)
                          as PageRoute<void>,
                    ),
                    child: const Text('open'),
                  ),
                );
              },
            ),
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
      await _sendBackGestureMethod('startBackGesture', {
        'touchOffset': <double>[5.0, 300.0],
        'progress': 0.0,
        'swipeEdge': 0,
      });
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
