import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/app/widgets/replica_button.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';
import 'package:pixiv_func/core/settings/settings_controller.dart';
import 'package:pixiv_func/core/settings/settings_repository.dart';
import 'package:pixiv_func/features/login/login_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

/// Settings storage stub: serves a fixed snapshot and records writes.
class _StubSettingsRepository implements SettingsRepository {
  _StubSettingsRepository([AppSettings? initial])
    : settings =
          initial ??
          const AppSettings(
            guideCompleted: true,
            languageTag: 'zh-CN',
            themeCode: AppSettings.systemTheme,
          );

  AppSettings settings;

  @override
  Future<AppSettings> load() async => settings;

  @override
  Future<void> save(AppSettings next) async {
    settings = next;
  }
}

/// The viewports the PRD calls out for the login page: narrowest portrait,
/// a common phone, a wide desktop surface and the short landscape case that
/// used to overflow the fixed-height layout.
const _viewports = [
  Size(320, 568),
  Size(390, 844),
  Size(1200, 800),
  Size(640, 320), // landscape / short height
];

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  Future<void> pumpLogin(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    bool isFirst = false,
    VoidCallback? onRegister,
    VoidCallback? onLogin,
    VoidCallback? onClipboardLogin,
    SettingsRepository? repository,
    List<Override> extraOverrides = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...accountProviderOverrides(),
          settingsRepositoryProvider.overrideWithValue(
            repository ?? _StubSettingsRepository(),
          ),
          ...extraOverrides,
        ],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: LoginPage(
            isFirst: isFirst,
            onRegister: onRegister,
            onLogin: onLogin,
            onClipboardLogin: onClipboardLogin,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('shell viewport matrix', () {
    for (final size in _viewports) {
      testWidgets('main actions stay visible and reachable at '
          '${size.width}x${size.height}', (tester) async {
        await pumpLogin(tester, size: size, isFirst: true);
        expect(tester.takeException(), isNull, reason: 'no overflow');

        for (final label in ['注册', '登录']) {
          final target = find.widgetWithText(ReplicaButton, label);
          expect(target, findsOneWidget, reason: '$label present');
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(tester.getRect(target).bottom, lessThanOrEqualTo(size.height));
        }
      });
    }

    testWidgets('wide viewports cap the form column at the form role width', (
      tester,
    ) async {
      await pumpLogin(tester, size: const Size(1200, 800));
      expect(tester.takeException(), isNull);

      // The content column is width-capped (ContentWidths.form = 520) and
      // centered, not spread across the whole surface.
      final actions = tester.getRect(find.widgetWithText(ReplicaButton, '登录'));
      expect(actions.width, lessThanOrEqualTo(520));
    });
  });

  group('structure', () {
    testWidgets('isFirst renders the title inside the shell header', (
      tester,
    ) async {
      await pumpLogin(tester, isFirst: true);
      expect(find.text('注册 或 登录'), findsOneWidget);
      // The onboarding variant keeps the title in the body header, not in
      // the AppBar.
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('注册 或 登录'),
        ),
        findsNothing,
      );
    });

    testWidgets('non-first login puts the title in the app bar', (
      tester,
    ) async {
      await pumpLogin(tester);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('注册 或 登录'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('agreement text and link stay under the actions', (
      tester,
    ) async {
      await pumpLogin(tester);
      expect(find.text('登录即表示您同意'), findsOneWidget);
      final link = find.text('《Pixiv Func用户使用协议》');
      expect(link, findsOneWidget);
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
