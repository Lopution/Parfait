import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixiv_func/core/settings/shared_preferences.dart';
import 'package:pixiv_func/core/updater/update_providers.dart';
import 'package:pixiv_func/core/updater/update_service.dart';
import 'package:pixiv_func/features/settings/settings_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

import 'helpers/test_preferences.dart';

/// Captures outbound `launch` calls on the url_launcher method channel —
/// the app calls `launchUrl`, which the platform interface forwards as a
/// `launch` invocation carrying the resolved url.
List<String> mockUrlLauncher(WidgetTester tester) {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final launched = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
    call,
  ) async {
    if (call.method == 'launch') {
      launched.add((call.arguments as Map)['url'] as String);
    }
    return true;
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
  return launched;
}

/// Captures `Clipboard.setData` payloads on the platform channel — there is
/// no real clipboard in tests, so the writes would otherwise be lost.
List<String?> mockClipboard(WidgetTester tester) {
  final written = <String?>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        written.add((call.arguments as Map)['text'] as String?);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return written;
}

void main() {
  Future<void> pumpAbout(WidgetTester tester) async {
    final service = UpdateService(
      manifestTransport: _UnusedTransport(),
      platform: _FdroidPlatform(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [updateServiceProvider.overrideWith((ref) async => service)],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: const AboutSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'F-Droid About explains store updates without an updater button',
    (tester) async {
      await pumpAbout(tester);

      expect(find.text('此构建由 F-Droid 管理更新。'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '检查更新'), findsNothing);
    },
  );

  testWidgets('source tile opens the repository in the browser', (
    tester,
  ) async {
    final launched = mockUrlLauncher(tester);
    await pumpAbout(tester);

    await tester.tap(find.text('项目源码'));
    await tester.pumpAndSettle();

    expect(launched, ['https://github.com/Lopution/Pixiv-func']);
  });

  testWidgets('source tile trailing action copies the repository URL', (
    tester,
  ) async {
    final written = mockClipboard(tester);
    await pumpAbout(tester);

    await tester.tap(find.byTooltip('复制'));
    await tester.pumpAndSettle();

    expect(written, ['https://github.com/Lopution/Pixiv-func']);
    expect(find.text('链接已复制'), findsOneWidget);
  });

  testWidgets('seven version taps unlock developer options', (tester) async {
    final service = UpdateService(
      manifestTransport: _UnusedTransport(),
      platform: _FdroidPlatform(),
    );
    installMemoryPreferences();
    final container = ProviderContainer(
      overrides: [updateServiceProvider.overrideWith((ref) async => service)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: const AboutSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(developerOptionsProvider), isFalse);
    for (var i = 0; i < 7; i++) {
      await tester.tap(find.text('版本'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(container.read(developerOptionsProvider), isTrue);
    // The unlock snackbar queues behind the countdown ones — provider state
    // is the assertion that matters; the message itself is l10n-covered.
  });
}

class _FdroidPlatform implements UpdatePlatform {
  @override
  Future<UpdateCapability> capability() async =>
      const UpdateCapability.fdroid();

  @override
  Future<UpdatePlatformInfo> info() => throw StateError('not used');

  @override
  Future<UpdateManifestVerification> verifyManifestSignature({
    required List<int> message,
    required List<int> signature,
  }) => throw StateError('not used');

  @override
  Future<UpdateApkVerification> verifyApk({
    required String path,
    required UpdateReleaseAsset asset,
  }) => throw StateError('not used');

  @override
  Future<UpdateInstallResult> installApk(String path) =>
      throw StateError('not used');

  @override
  Future<bool> deleteApk(String path) => throw StateError('not used');
}

class _UnusedTransport implements UpdateManifestTransport {
  @override
  Future<UpdateHttpResponse> fetch(Uri uri) => throw StateError('not used');
}
