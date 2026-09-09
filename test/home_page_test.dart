import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
import 'package:pixiv_func/app/icons/app_icons.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/platform/android_intent_channel.dart';
import 'package:pixiv_func/core/platform/intent_router.dart';
import 'package:pixiv_func/core/platform/root_back_coordinator.dart';
import 'package:pixiv_func/features/home/home_page.dart';
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

class _StaticCredentialStore implements CredentialStore {
  const _StaticCredentialStore();

  @override
  Future<Credential?> read(String accountId) async =>
      Credential(accessToken: 'a-$accountId', refreshToken: 'r-$accountId');

  @override
  Future<void> write(String accountId, Credential credential) async {}

  @override
  Future<void> delete(String accountId) async {}
}

class _StaticMetadataRepository implements AccountMetadataRepository {
  const _StaticMetadataRepository(this.snapshot);

  final AccountMetadataSnapshot snapshot;

  @override
  Future<AccountMetadataSnapshot> load() async => snapshot;

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

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
  return ProviderScope(
    overrides: [
      credentialStoreProvider.overrideWithValue(const _StaticCredentialStore()),
      accountMetadataRepositoryProvider.overrideWithValue(
        const _StaticMetadataRepository(_signedInSnapshot),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale ?? const Locale('zh', 'CN'),

      home: HomePage(
        intentSource:
            intentSource ??
            const _ScriptedIntentSource(
              IgnoredAndroidIntent('test: no android intent'),
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
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            credentialStoreProvider.overrideWithValue(
              const _StaticCredentialStore(),
            ),
            accountMetadataRepositoryProvider.overrideWithValue(
              const _StaticMetadataRepository(
                AccountMetadataSnapshot(
                  accounts: [Account(id: '100', userId: 100, name: 'tester')],
                  currentId: '100',
                ),
              ),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),

            home: HomePage(),
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

      // A second press inside the window exits via SystemNavigator.pop; in
      // the test environment that is a no-op that must not throw.
      await tester.binding.handlePopRoute();
      await tester.pump();
    },
  );

  testWidgets('root back coordinator window is one second', (tester) async {
    expect(RootBackCoordinator.exitWindow, const Duration(seconds: 1));
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

  testWidgets('NavigationBar labels render in every supported locale', (
    tester,
  ) async {
    for (final locale in AppLocalizations.supportedLocales) {
      await _pumpHome(tester, locale: locale);
      expect(find.byType(NavigationBar), findsOneWidget);
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
