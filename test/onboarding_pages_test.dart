import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/app/scroll_behavior.dart';
import 'package:parfait/app/widgets/replica_button.dart';
import 'package:parfait/app/widgets/settings/settings_choice_tile.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/settings/settings_repository.dart';
import 'package:parfait/features/onboarding/language_page.dart';
import 'package:parfait/features/onboarding/user_agreement_page.dart';
import 'package:parfait/features/onboarding/welcome_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
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
    Locale? locale,
    ScrollBehavior? scrollBehavior,
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
            locale: locale ?? const Locale('zh', 'CN'),
            scrollBehavior: scrollBehavior,
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

    testWidgets('language next completes the guide and opens login', (
      tester,
    ) async {
      final repository = _StubSettingsRepository();
      final r = await pumpFlow(
        tester,
        initialLocation: '/welcome/language',
        repository: repository,
      );
      expect(find.byType(LanguagePage), findsOneWidget);

      await tester.tap(find.byType(ReplicaButton));
      await tester.pumpAndSettle();

      expect(repository.saved.last.guideCompleted, isTrue);
      expect(find.text('LOGIN-MARKER'), findsOneWidget);
      expect(r.state.uri.path, '/login');
      expect(r.state.uri.queryParameters['first'], 'true');
      expect(r.state.uri.queryParameters['return'], 'true');
    });

    testWidgets('the language page has one action and no skip', (tester) async {
      await pumpFlow(tester, initialLocation: '/welcome/language');

      expect(find.byType(ReplicaButton), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.text('稍后设置'), findsNothing);
    });
  });

  group('language choice', () {
    testWidgets('options are single-choice rows that apply at once', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      final repository = _StubSettingsRepository();
      await pumpPage(
        tester,
        const Size(390, 844),
        const LanguagePage(),
        repository: repository,
      );

      expect(find.byType(SettingsChoiceTile), findsNWidgets(4));
      expect(
        tester.getSemantics(find.widgetWithText(SettingsChoiceTile, '简体中文')),
        isSemantics(isSelected: true, hasSelectedState: true),
      );

      await tester.tap(find.text('日本語'));
      await tester.pumpAndSettle();

      expect(repository.saved.last.languageTag, 'ja-JP');
      expect(
        tester.getSemantics(find.widgetWithText(SettingsChoiceTile, '日本語')),
        isSemantics(isSelected: true, hasSelectedState: true),
      );
      expect(
        tester.getSemantics(find.widgetWithText(SettingsChoiceTile, '简体中文')),
        isSemantics(isSelected: false, hasSelectedState: true),
      );
      // The page's own text follows the choice right away.
      expect(find.text('言語の選択'), findsOneWidget);
    });
  });

  group('titles', () {
    testWidgets('the language title wraps instead of shrinking', (
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
      final title = tester.widget<Text>(find.text('选择您的语言'));
      final theme = Theme.of(tester.element(find.text('选择您的语言')));
      expect(title.style, theme.textTheme.headlineMedium);
    });

    testWidgets('welcome lockup lines wrap instead of shrinking', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await pumpPage(tester, const Size(320, 568), const WelcomePage());
      // Shrinking long translations below 0.8 is not allowed; the full-size
      // lines wrap (real-width coverage lives in the locale layout matrix).
      expect(find.byType(FittedBox), findsNothing);
      final line = tester.widget<Text>(find.text('感谢使用Parfait'));
      expect(line.maxLines, isNull);
      final theme = Theme.of(tester.element(find.text('感谢使用Parfait')));
      expect(line.style, theme.textTheme.headlineMedium);
    });

    testWidgets('welcome shows the app mark as decoration', (tester) async {
      addTearDown(tester.view.reset);
      await pumpPage(tester, const Size(390, 844), const WelcomePage());

      final mark = tester.widget<Image>(find.byType(Image));
      expect(
        (mark.image as AssetImage).assetName,
        'assets/branding/parfait_icon.png',
      );
      expect(mark.width, 96);
      expect(mark.excludeFromSemantics, isTrue);
      final detail = tester.widget<Text>(find.text('下面将进行首次启动设置'));
      final theme = Theme.of(tester.element(find.text('下面将进行首次启动设置')));
      expect(detail.style!.fontSize, theme.textTheme.bodyLarge!.fontSize);
      expect(detail.style!.color, theme.colorScheme.onSurfaceVariant);
    });
  });
  group('user agreement', () {
    testWidgets('body is selectable and width-capped on wide viewports', (
      tester,
    ) async {
      addTearDown(tester.view.reset);

      await pumpPage(tester, const Size(1200, 800), const UserAgreementPage());
      expect(tester.takeException(), isNull);

      // One selection region over plain Text: no paragraph owns a
      // Scrollable of its own.
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(
        find.descendant(
          of: find.byType(UserAgreementPage),
          matching: find.byType(Scrollable),
        ),
        findsOneWidget,
      );
      final list = tester.getRect(find.byType(ListView));
      expect(list.width, lessThanOrEqualTo(700));
    });

    testWidgets('a drag on a paragraph scrolls the whole page', (tester) async {
      addTearDown(tester.view.reset);
      final zh = lookupAppLocalizations(const Locale('zh'));
      // The app's always-scrollable bouncing physics used to leak into each
      // paragraph's own Scrollable, letting it drag on its own.
      await pumpPage(
        tester,
        const Size(390, 844),
        const UserAgreementPage(),
        scrollBehavior: const FuncScrollBehavior(),
      );

      final position = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      expect(position.pixels, 0);
      await tester.drag(
        find.text(zh.agreementAccountBody),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
    });

    for (final locale in const [Locale('zh'), Locale('ru')]) {
      testWidgets('every section title is reachable in $locale', (
        tester,
      ) async {
        addTearDown(tester.view.reset);
        final l10n = lookupAppLocalizations(locale);
        await pumpPage(
          tester,
          const Size(320, 568),
          const UserAgreementPage(),
          textScale: 1.3,
          locale: locale,
        );
        final titles = [
          l10n.agreementServiceTitle,
          l10n.agreementAccountTitle,
          l10n.agreementUsageTitle,
          l10n.agreementContentTitle,
          l10n.agreementNetworkTitle,
          l10n.agreementThirdPartyTitle,
          l10n.agreementPrivacyTitle,
          l10n.agreementDisclaimerTitle,
          l10n.agreementUpdatesTitle,
        ];
        expect(titles.toSet(), hasLength(9));
        for (final title in titles) {
          await tester.scrollUntilVisible(
            find.text(title),
            200,
            scrollable: find.byType(Scrollable),
          );
          expect(tester.takeException(), isNull, reason: title);
        }
      });
    }
  });
}
