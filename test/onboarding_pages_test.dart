import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/app/widgets/replica_button.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/features/onboarding/language_page.dart';
import 'package:parfait/features/onboarding/user_agreement_page.dart';
import 'package:parfait/features/onboarding/welcome_page.dart';

import 'helpers/fake_settings.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';

/// Settings a first launch finds: the guide not yet completed.
const _firstLaunch = AppSettings(
  guideCompleted: false,
  languageTag: 'zh-CN',
  themeCode: AppSettings.systemTheme,
);

void main() {
  group('navigation', () {
    GoRouter router(String initialLocation) {
      return GoRouter(
        initialLocation: initialLocation,
        routes: [
          GoRoute(
            path: '/welcome',
            builder: (_, _) => const WelcomePage(),
            routes: [
              GoRoute(
                path: 'language',
                builder: (_, _) => const LanguagePage(),
              ),
            ],
          ),
          GoRoute(
            path: '/login',
            builder: (_, _) => const Scaffold(body: Text('LOGIN-MARKER')),
          ),
          GoRoute(
            path: '/user-agreement',
            builder: (_, _) => const UserAgreementPage(),
          ),
        ],
      );
    }

    Future<GoRouter> pumpFlow(
      WidgetTester tester, {
      String initialLocation = '/welcome',
    }) async {
      // Comfortable phone viewport — every control on screen without
      // scrolling; the matrix group owns the short-viewport assertions.
      setViewSize(tester, const Size(390, 844));
      final r = router(initialLocation);
      addTearDown(r.dispose);
      await seedSettings(_firstLaunch);
      await tester.pumpWidget(localizedRouterApp(r, overrides: const []));
      await tester.pumpAndSettle();
      return r;
    }

    testWidgets('an agreement opened on its own still leads back to login', (
      tester,
    ) async {
      for (final viaSystemBack in [false, true]) {
        final r = await pumpFlow(tester, initialLocation: '/user-agreement');
        expect(find.byType(BackButtonIcon), findsOneWidget);

        if (viaSystemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byType(BackButtonIcon));
        }
        await tester.pumpAndSettle();

        expect(find.text('LOGIN-MARKER'), findsOneWidget);
        expect(r.state.uri.path, '/login');
      }
    });

    testWidgets('language next completes the guide and opens login', (
      tester,
    ) async {
      final r = await pumpFlow(tester, initialLocation: '/welcome/language');
      expect(find.byType(LanguagePage), findsOneWidget);

      await tester.tap(find.byType(ReplicaButton));
      await tester.pumpAndSettle();

      expect((await storedSettings().load()).guideCompleted, isTrue);
      expect(find.text('LOGIN-MARKER'), findsOneWidget);
      expect(r.state.uri.path, '/login');
      expect(r.state.uri.queryParameters['first'], 'true');
      expect(r.state.uri.queryParameters['return'], 'true');
    });
  });
}
