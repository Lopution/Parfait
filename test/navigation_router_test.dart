import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'helpers/test_preferences.dart';
import 'package:pixiv_func/app/icons/app_icons.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/features/home/recommended/recommended_home_page.dart';
import 'package:pixiv_func/features/ranking/ranking_page.dart';
import 'package:pixiv_func/features/new/new_page.dart';
import 'package:pixiv_func/features/search/search_page.dart';
import 'package:pixiv_func/features/settings/settings_page.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('shell owns the active tab and preserves branch stacks', (
    tester,
  ) async {
    final router = createPixivRouter(initialLocation: '/recommended');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(StatefulNavigationShell), findsOneWidget);
    expect(find.byType(RecommendedHomePage), findsOneWidget);
    expect(find.byType(RankingPage, skipOffstage: false), findsNothing);
    expect(find.byType(NewPage, skipOffstage: false), findsNothing);
    expect(find.byType(SearchHomePage, skipOffstage: false), findsNothing);
    expect(find.byType(SettingsPage, skipOffstage: false), findsNothing);

    await tester.tap(find.byIcon(AppIcons.ranking));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(router.state.uri.path, '/ranking');
    expect(find.byType(RankingPage, skipOffstage: false), findsOneWidget);
    expect(find.byType(NewPage, skipOffstage: false), findsNothing);

    await tester.tap(find.byIcon(AppIcons.home));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(router.state.uri.path, '/recommended');
    expect(find.byType(RecommendedHomePage), findsOneWidget);
    expect(find.byType(RankingPage, skipOffstage: false), findsOneWidget);
  });
}
