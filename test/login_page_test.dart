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

import 'dart:async';

import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_transfer_service.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

/// Clipboard import stub whose result future the test controls, so the
/// busy state can be observed deterministically.
class _ControlledTransferService implements AccountTransferService {
  final completer = Completer<TransferImportResult>();
  int importCalls = 0;

  @override
  Future<TransferImportResult> importFromClipboard() {
    importCalls++;
    return completer.future;
  }

  @override
  Future<void> exportCurrentToClipboard() async {}
}

/// Settings storage stub that always fails to load — drives the page into
/// its [SettingsLoadError] branch.
class _FailingSettingsRepository implements SettingsRepository {
  @override
  Future<AppSettings> load() => throw StateError('prefs unreadable');

  @override
  Future<void> save(AppSettings next) async {}
}

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
    double textScale = 1,
    bool isFirst = false,
    VoidCallback? onRegister,
    VoidCallback? onLogin,
    VoidCallback? onClipboardLogin,
    SettingsRepository? repository,
    Locale? locale,
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
        child: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: locale ?? const Locale('zh', 'CN'),
            home: LoginPage(
              isFirst: isFirst,
              onRegister: onRegister,
              onLogin: onLogin,
              onClipboardLogin: onClipboardLogin,
            ),
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

    testWidgets('long ru translations keep the main actions reachable', (
      tester,
    ) async {
      // The login page resolves strings from the persisted settings tag,
      // so ru coverage comes from the repository, not the app locale.
      await pumpLogin(
        tester,
        size: const Size(320, 568),
        textScale: 1.3,
        isFirst: true,
        repository: _StubSettingsRepository(
          const AppSettings(
            guideCompleted: true,
            languageTag: 'ru-RU',
            themeCode: AppSettings.systemTheme,
          ),
        ),
        locale: const Locale('ru'),
      );
      expect(tester.takeException(), isNull, reason: 'no overflow');

      for (final label in ['Регистрация', 'Вход']) {
        final target = find.widgetWithText(ReplicaButton, label);
        expect(target, findsOneWidget, reason: '$label present');
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(target).bottom,
          lessThanOrEqualTo(568),
        );
      }
    });

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

  group('action layering', () {
    Future<void> expandHelp(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
    }

    testWidgets('help expansion keeps register and login tappable', (
      tester,
    ) async {
      var registered = 0;
      var loggedIn = 0;
      await pumpLogin(
        tester,
        size: const Size(390, 844),
        onRegister: () => registered++,
        onLogin: () => loggedIn++,
      );
      await expandHelp(tester);
      expect(tester.takeException(), isNull);

      // Secondary zone content is revealed…
      expect(find.textContaining('默认直连'), findsOneWidget);
      expect(find.text('使用剪贴板数据登录'), findsOneWidget);
      expect(find.textContaining('剪贴板内容会短时存在'), findsOneWidget);
      // …and the dead "get more help" affordance is gone.
      expect(find.textContaining('获取更多帮助'), findsNothing);

      // …while the primary row is still present and functional.
      final register = find.widgetWithText(ReplicaButton, '注册');
      final login = find.widgetWithText(ReplicaButton, '登录');
      await tester.ensureVisible(register);
      await tester.ensureVisible(login);
      await tester.pumpAndSettle();
      await tester.tap(register);
      await tester.tap(login);
      expect(registered, 1);
      expect(loggedIn, 1);
    });

    testWidgets('clipboard import shows a busy state and debounces taps', (
      tester,
    ) async {
      final service = _ControlledTransferService();
      await pumpLogin(
        tester,
        size: const Size(390, 844),
        extraOverrides: [
          accountTransferServiceProvider.overrideWithValue(service),
        ],
      );
      await expandHelp(tester);

      final button = find.widgetWithText(OutlinedButton, '使用剪贴板数据登录');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();

      await tester.tap(button);
      await tester.pump();
      expect(service.importCalls, 1);
      // Busy: progress indicator in the label area and the action disabled.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);

      // A second tap during the import must not start another one.
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      expect(service.importCalls, 1);

      service.completer.complete(
        const TransferImportResult(
          account: Account(id: '1', userId: 1, name: 'Tester'),
          clipboardCleared: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    });

    testWidgets('register and login open the proxy notice dialog', (
      tester,
    ) async {
      await pumpLogin(tester, size: const Size(390, 844));

      await tester.tap(find.widgetWithText(ReplicaButton, '登录'));
      await tester.pumpAndSettle();

      // The proxy notice stays a dialog on every breakpoint (D7).
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(find.text('提示'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('我已开启代理'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(find.byType(LoginPage), findsOneWidget);
    });

    testWidgets('a settings read failure shows the shared error branch', (
      tester,
    ) async {
      await pumpLogin(tester, repository: _FailingSettingsRepository());
      expect(find.byKey(const Key('settings-load-error')), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      // The login actions are not rendered on top of the failure.
      expect(find.widgetWithText(ReplicaButton, '登录'), findsNothing);
    });
  });
}
