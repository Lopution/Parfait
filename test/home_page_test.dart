import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/app/app.dart';
import 'package:pixiv_func/app/icons/app_icons.dart';
import 'package:pixiv_func/app/external_intent_bridge.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/platform/android_intent_channel.dart';
import 'package:pixiv_func/core/platform/intent_router.dart';
import 'package:pixiv_func/core/platform/platform_caps.dart';
import 'package:pixiv_func/core/platform/root_back_coordinator.dart';
import 'package:pixiv_func/features/home/recommended/recommended_home_page.dart';
import 'package:pixiv_func/features/illust/detail/illust_detail_page.dart';
import 'package:pixiv_func/features/new/new_page.dart';
import 'package:pixiv_func/features/profile/user_page.dart';
import 'package:pixiv_func/features/ranking/ranking_page.dart';
import 'package:pixiv_func/features/search/search_page.dart';
import 'package:pixiv_func/features/settings/settings_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'package:pixiv_func/app/widgets/func_bottom_nav.dart';

class _ScriptedIntentSource implements AndroidIntentSource {
  const _ScriptedIntentSource(this.initial);

  final AndroidIntentResult initial;

  @override
  Future<AndroidIntentResult> readInitial() async => initial;

  @override
  Stream<AndroidIntentResult> get onNewIntent => const Stream.empty();
}

const _signedInSnapshot = AccountMetadataSnapshot(
  accounts: [Account(id: '100', userId: 100, name: 'tester')],
  currentId: '100',
);

Widget _homeApp({AndroidIntentSource? intentSource, Locale? locale}) {
  final source =
      intentSource ??
      const _ScriptedIntentSource(
        IgnoredAndroidIntent('test: no android intent'),
      );
  final router = createPixivRouter(initialLocation: '/recommended');
  final credentials = FakeCredentialStore(
    values: const {
      '100': Credential(accessToken: 'a-100', refreshToken: 'r-100'),
    },
  );
  final metadata = FakeAccountMetadataRepository(
    accounts: _signedInSnapshot.accounts,
    currentId: _signedInSnapshot.currentId,
  );
  return ProviderScope(
    overrides: [
      ...accountProviderOverrides(
        credentialStore: credentials,
        metadataRepository: metadata,
      ),
    ],
    child: MaterialApp.router(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale ?? const Locale('zh', 'CN'),
      routerConfig: router,
      builder: (context, child) => ExternalIntentBridge(
        router: router,
        intentSource: source,
        child: child!,
      ),
    ),
  );
}

Future<void> _pumpHome(
  WidgetTester tester, {
  AndroidIntentSource? intentSource,
  Locale? locale,
}) async {
  // Pin a compact surface so the shell renders the bottom navigation bar
  // rather than the wide NavigationRail.
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_homeApp(intentSource: intentSource, locale: locale));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets(
    'U4: exit hint snackbar lifetime equals the root back exit window',
    (tester) async {
      // Pin a compact surface so the shell renders the bottom bar whose
      // measured height the hint's margin is asserted against.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // Root double-back-to-exit is Android-only; the test host is
            // Linux, so the coordinator path needs Android caps injected.
            platformCapsProvider.overrideWithValue(
              const PlatformCaps(isAndroid: true),
            ),
            ...accountProviderOverrides(
              credentialStore: FakeCredentialStore(
                values: const {
                  '100': Credential(
                    accessToken: 'a-100',
                    refreshToken: 'r-100',
                  ),
                },
              ),
              metadataRepository: FakeAccountMetadataRepository(
                accounts: _signedInSnapshot.accounts,
                currentId: _signedInSnapshot.currentId,
              ),
            ),
          ],
          child: MaterialApp.router(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            routerConfig: createPixivRouter(initialLocation: '/recommended'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // First root back press arms the exit window and shows the hint.
      await tester.binding.handlePopRoute();
      await tester.pump();

      final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
      // The hint must not outlive the window it describes (U4: the default
      // 4-second SnackBar was still showing after the window had closed).
      expect(snackBar.duration, RootBackCoordinator.exitWindow);
      expect(snackBar.behavior, SnackBarBehavior.floating);
      expect(find.text('再按一次退出'), findsOneWidget);

      // The hint clears the shell bottom bar: the floating margin grows by
      // the bar's computed resting extent, and the rendered card never
      // touches the bar.
      final barExtent = tester.getSize(find.byType(FuncBottomNav)).height;
      expect(snackBar.margin, EdgeInsets.fromLTRB(16, 0, 16, 16 + barExtent));
      final card = tester.getRect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.byType(Material),
        ),
      );
      final bar = tester.getRect(find.byType(FuncBottomNav));
      expect(card.overlaps(bar), isFalse);

      // A second press inside the window exits via SystemNavigator.pop; in
      // the test environment that is a no-op that must not throw.
      await tester.binding.handlePopRoute();
      await tester.pump();
    },
  );

  testWidgets('root back coordinator window is one second', (tester) async {
    expect(RootBackCoordinator.exitWindow, const Duration(seconds: 1));
  });

  testWidgets(
    'update prompt clears the shell bar and times out at eight seconds',
    (tester) async {
      await _pumpHome(tester);
      await tester.pumpAndSettle();

      final host = tester.element(find.byType(FuncShellBottomNav));
      showUpdatePrompt(
        ScaffoldMessenger.of(host),
        version: '9.9.9',
        shellBarVisible: true,
        reduceMotion: false,
        onOpen: () {},
      );
      await tester.pump();
      await tester.pumpAndSettle();

      final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snackBar.duration, updatePromptDuration);
      expect(find.text('发现新版本: 9.9.9'), findsOneWidget);
      // The shared shell margin lifts the card fully above the bar.
      final card = tester.getRect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.byWidgetPredicate(
            (w) => w is Material && w.type == MaterialType.canvas,
          ),
        ),
      );
      final bar = tester.getRect(find.byType(FuncBottomNav));
      expect(card.overlaps(bar), isFalse);

      // D2: the prompt is still shown mid-dwell; once the 8-second dwell
      // plus its exit flight have passed it is gone — the action never
      // pins it.
      await tester.pump(const Duration(seconds: 7));
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  group('three-tier navigation chrome', () {
    Future<void> pumpAt(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_homeApp());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    bool railExtended(WidgetTester tester) {
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      return rail.extended;
    }

    testWidgets('compact surface keeps the bottom bar and no rail', (
      tester,
    ) async {
      await pumpAt(tester, 390);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('medium surface uses the compact rail', (tester) async {
      await pumpAt(tester, 900);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(railExtended(tester), isFalse);
    });

    testWidgets('1199 stays compact, 1200 switches to the extended rail', (
      tester,
    ) async {
      await pumpAt(tester, 1199);
      expect(railExtended(tester), isFalse);

      tester.view.physicalSize = const Size(1200, 844);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(railExtended(tester), isTrue);
    });
  });

  testWidgets('C7: cold start builds only the current tab', (tester) async {
    await _pumpHome(tester);

    expect(find.byType(RecommendedHomePage), findsOneWidget);
    // IndexedStack offstages inactive children; search offstage so a
    // prebuilt tab cannot hide behind skipOffstage: true.
    expect(find.byType(RankingPage, skipOffstage: false), findsNothing);
    expect(find.byType(NewPage, skipOffstage: false), findsNothing);
    expect(find.byType(SearchHomePage, skipOffstage: false), findsNothing);
    expect(find.byType(SettingsPage, skipOffstage: false), findsNothing);
  });

  testWidgets('C7: visited tabs stay alive and keep the first tab controller', (
    tester,
  ) async {
    await _pumpHome(tester);

    final firstRecommended = tester.state<State<RecommendedHomePage>>(
      find.byType(RecommendedHomePage),
    );

    await tester.tap(find.byIcon(AppIcons.ranking));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byType(RecommendedHomePage, skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byType(RankingPage, skipOffstage: false), findsOneWidget);
    expect(find.byType(SettingsPage, skipOffstage: false), findsNothing);

    await tester.tap(find.byIcon(AppIcons.home));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      identical(
        tester.state<State<RecommendedHomePage>>(
          find.byType(RecommendedHomePage),
        ),
        firstRecommended,
      ),
      isTrue,
    );
    expect(find.byType(RankingPage, skipOffstage: false), findsOneWidget);
    expect(find.byType(SettingsPage, skipOffstage: false), findsNothing);
  });

  testWidgets('Bottom navigation labels render in every supported locale', (
    tester,
  ) async {
    for (final locale in AppLocalizations.supportedLocales) {
      await _pumpHome(tester, locale: locale);
      expect(find.byType(FuncBottomNav), findsOneWidget);
    }
  });

  testWidgets('C8: UserRoute delivered to home pushes the user page', (
    tester,
  ) async {
    await _pumpHome(
      tester,
      intentSource: const _ScriptedIntentSource(
        RoutedAndroidIntent(UserRoute(123)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(UserPage), findsOneWidget);
    expect(tester.widget<UserPage>(find.byType(UserPage)).userId, 123);
  });

  testWidgets(
    'C8: UnknownRoute shows the rejection snackbar and does not navigate',
    (tester) async {
      final unknown = IntentRouter.routePlatformMessage({
        'action': AndroidIntentInput.viewAction,
        'uri': 'https://www.pixiv.net/unknown-path',
      });
      expect(unknown, isA<RejectedAndroidIntent>());

      await _pumpHome(tester, intentSource: _ScriptedIntentSource(unknown));
      await tester.pump();
      await tester.pump();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('分享的图片无法使用'), findsOneWidget);
      expect(find.byType(UserPage), findsNothing);
      expect(find.byType(IllustDetailPage), findsNothing);
    },
  );
}
