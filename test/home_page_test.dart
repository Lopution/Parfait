import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/app.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/external_intent_bridge.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/prompt_host.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_repository.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/platform/android_intent_channel.dart';
import 'package:parfait/core/platform/intent_router.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/new/new_page.dart';
import 'package:parfait/features/profile/user_page.dart';
import 'package:parfait/features/ranking/ranking_page.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/fake_account.dart';
import 'helpers/prompt_host.dart';
import 'helpers/test_preferences.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';

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
      builder: (context, child) => promptHostBuilder(
        context,
        ExternalIntentBridge(
          router: router,
          intentSource: source,
          child: child!,
        ),
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
    'update prompt clears the shell bar and times out at eight seconds',
    (tester) async {
      await _pumpHome(tester);
      await tester.pumpAndSettle();

      final shell = tester.element(find.byType(FuncShellBottomNav));
      showUpdatePrompt(PromptHost.of(shell), version: '9.9.9', onOpen: () {});
      await tester.pump();
      await tester.pumpAndSettle();

      const message = '发现新版本: 9.9.9';
      expect(find.text(message), findsOneWidget);
      // The bar anchors the prompt: the card rests fully above it.
      final card = tester.getRect(promptCard(message));
      final bar = tester.getRect(find.byType(FuncBottomNav));
      expect(card.overlaps(bar), isFalse);
      expect(card.bottom, closeTo(bar.top - 16, 0.5));

      // D2: the prompt is still shown mid-dwell; once the 8-second dwell
      // plus its exit flight have passed it is gone — the action never
      // pins it.
      await tester.pump(const Duration(seconds: 7));
      expect(find.text(message), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
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

      expect(shownPrompt, findsOneWidget);
      expect(find.text('分享的图片无法使用'), findsOneWidget);
      expect(find.byType(UserPage), findsNothing);
      expect(find.byType(IllustDetailPage), findsNothing);
    },
  );
}
