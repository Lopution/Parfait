import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/widgets/replica_button.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/settings/settings_repository.dart';
import 'package:parfait/features/login/login_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'dart:async';

import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_transfer_service.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';

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
            builder: promptHostBuilder,
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

  group('action layering', () {
    final zh = lookupAppLocalizations(const Locale('zh'));
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
      expect(find.text(zh.networkCompatibilityHint), findsNothing);
      await expandHelp(tester);
      expect(tester.takeException(), isNull);

      // The toggle reveals only the network note…
      expect(find.text(zh.networkCompatibilityHint), findsOneWidget);
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

    testWidgets('clipboard sign-in is visible without the help toggle', (
      tester,
    ) async {
      await pumpLogin(tester, size: const Size(390, 844));

      final button = find.widgetWithText(OutlinedButton, '使用剪贴板数据登录');
      expect(button, findsOneWidget);
      // The hint says where the data comes from and keeps the risk note.
      final hint = find.textContaining('导出账号凭据');
      expect(hint, findsOneWidget);
      expect(tester.widget<Text>(hint).data, contains('剪贴板内容会短时存在'));
      // It sits under the register/login row, above the agreement line.
      final login = find.widgetWithText(ReplicaButton, '登录');
      expect(
        tester.getTopLeft(button).dy,
        greaterThan(tester.getBottomLeft(login).dy),
      );
      expect(
        tester.getBottomLeft(hint).dy,
        lessThan(tester.getTopLeft(find.text('登录即表示你同意')).dy),
      );
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
  });
}
