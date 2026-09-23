import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pixiv_func/app/widgets/replica_button.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';
import 'package:pixiv_func/core/settings/settings_controller.dart';
import 'package:pixiv_func/core/settings/settings_repository.dart';
import 'package:pixiv_func/features/onboarding/language_page.dart';
import 'package:pixiv_func/features/onboarding/theme_page.dart';
import 'package:pixiv_func/features/onboarding/user_agreement_page.dart';
import 'package:pixiv_func/features/onboarding/welcome_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/test_preferences.dart';

/// Settings storage stub: serves a fixed snapshot and records writes so
/// tests can assert `completeGuide()` really persisted.
class _StubSettingsRepository implements SettingsRepository {
  _StubSettingsRepository([AppSettings? initial])
    : settings =
          initial ??
          const AppSettings(
            guideCompleted: false,
            languageTag: 'zh-CN',
            themeCode: AppSettings.systemTheme,
          );

  AppSettings settings;
  final saved = <AppSettings>[];

  @override
  Future<AppSettings> load() async => settings;

  @override
  Future<void> save(AppSettings next) async {
    settings = next;
    saved.add(next);
  }
}

/// The acceptance matrix: narrowest portrait, a common phone, both
/// breakpoints, expanded desktop width and a short landscape viewport.
const _viewports = [
  Size(320, 568),
  Size(390, 844),
  Size(600, 960),
  Size(840, 1180),
  Size(1200, 800),
  Size(640, 320), // landscape / short height
];

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  Future<void> pumpPage(
    WidgetTester tester,
    Size size,
    Widget page, {
    double textScale = 1,
    SettingsRepository? repository,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(
              repository ?? _StubSettingsRepository(),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: page,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('shell viewport matrix', () {
    final pages = <String, Widget>{
      'welcome': const WelcomePage(),
      'language': const LanguagePage(),
      'theme': const ThemePage(),
    };
    for (final scale in const [1.0, 1.3]) {
      for (final size in _viewports) {
        for (final entry in pages.entries) {
          testWidgets('${entry.key} page stays usable at '
              '${size.width}x${size.height} @${scale}x', (tester) async {
            addTearDown(tester.view.reset);
            await pumpPage(tester, size, entry.value, textScale: scale);
            expect(tester.takeException(), isNull, reason: 'no overflow');

            // The primary CTA must be reachable: pinned at the bottom on
            // tall viewports, scrollable to on short ones.
            final cta = find.byType(ReplicaButton);
            expect(cta, findsOneWidget);
            await tester.ensureVisible(cta);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final rect = tester.getRect(cta);
            expect(rect.bottom, lessThanOrEqualTo(size.height));
          });
        }
      }
    }
  });

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
              GoRoute(path: 'theme', builder: (_, _) => const ThemePage()),
            ],
          ),
          GoRoute(
            path: '/login',
            builder: (_, _) => const Scaffold(body: Text('LOGIN-MARKER')),
          ),
        ],
      );
    }

    Future<GoRouter> pumpFlow(
      WidgetTester tester, {
      String initialLocation = '/welcome',
      SettingsRepository? repository,
    }) async {
      // Comfortable phone viewport — every control on screen without
      // scrolling; the matrix group owns the short-viewport assertions.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final r = router(initialLocation);
      addTearDown(r.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(
              repository ?? _StubSettingsRepository(),
            ),
          ],
          child: MaterialApp.router(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            routerConfig: r,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return r;
    }

    testWidgets('welcome start pushes the language page', (tester) async {
      final r = await pumpFlow(tester);
      expect(find.byType(WelcomePage), findsOneWidget);

      await tester.tap(find.byType(ReplicaButton));
      await tester.pumpAndSettle();

      expect(find.byType(LanguagePage), findsOneWidget);
      expect(r.state.uri.path, '/welcome/language');
    });

    testWidgets('language next pushes the theme page', (tester) async {
      final r = await pumpFlow(tester, initialLocation: '/welcome/language');
      expect(find.byType(LanguagePage), findsOneWidget);

      await tester.tap(find.byType(ReplicaButton));
      await tester.pumpAndSettle();

      expect(find.byType(ThemePage), findsOneWidget);
      expect(r.state.uri.path, '/welcome/theme');
    });

    testWidgets('language later button advances like next', (tester) async {
      final r = await pumpFlow(tester, initialLocation: '/welcome/language');

      await tester.tap(find.text('稍后设置'));
      await tester.pumpAndSettle();

      expect(find.byType(ThemePage), findsOneWidget);
      expect(r.state.uri.path, '/welcome/theme');
    });

    testWidgets('theme next completes the guide and opens login', (
      tester,
    ) async {
      final repository = _StubSettingsRepository();
      final r = await pumpFlow(
        tester,
        initialLocation: '/welcome/theme',
        repository: repository,
      );

      await tester.tap(find.byType(ReplicaButton));
      await tester.pumpAndSettle();

      expect(repository.saved.last.guideCompleted, isTrue);
      expect(find.text('LOGIN-MARKER'), findsOneWidget);
      expect(r.state.uri.path, '/login');
      expect(r.state.uri.queryParameters['first'], 'true');
      expect(r.state.uri.queryParameters['return'], 'true');
    });

    testWidgets('theme later button advances like next', (tester) async {
      final repository = _StubSettingsRepository();
      final r = await pumpFlow(
        tester,
        initialLocation: '/welcome/theme',
        repository: repository,
      );

      await tester.tap(find.text('稍后设置'));
      await tester.pumpAndSettle();

      expect(repository.saved.last.guideCompleted, isTrue);
      expect(find.text('LOGIN-MARKER'), findsOneWidget);
      expect(r.state.uri.path, '/login');
    });
  });

  group('titles', () {
    testWidgets('language/theme titles wrap instead of shrinking', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      // Narrowest viewport + large text: a FittedBox(scaleDown) title would
      // shrink to unreadable; a wrapping title must not throw.
      await pumpPage(
        tester,
        const Size(320, 568),
        const LanguagePage(),
        textScale: 1.3,
      );
      expect(find.byType(FittedBox), findsNothing);
      expect(find.text('选择您的语言'), findsOneWidget);

      await pumpPage(
        tester,
        const Size(320, 568),
        const ThemePage(),
        textScale: 1.3,
      );
      expect(find.byType(FittedBox), findsNothing);
      expect(find.text('选择喜欢的主题'), findsOneWidget);
    });

    testWidgets('welcome keeps its two-line brand lockup', (tester) async {
      addTearDown(tester.view.reset);
      await pumpPage(tester, const Size(390, 844), const WelcomePage());
      // The brand lockup is intentionally scaleDown-anchored (per-page
      // design decision documented in welcome_page.dart).
      expect(find.byType(FittedBox), findsNWidgets(2));
    });
  });
}
