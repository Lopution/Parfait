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
  Future<void> pumpAbout(WidgetTester tester, {UpdateService? service}) async {
    final effectiveService =
        service ??
        UpdateService(
          manifestTransport: _UnusedTransport(),
          platform: _FdroidPlatform(),
        );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          updateServiceProvider.overrideWith((ref) async => effectiveService),
        ],
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

  // Each check failure state maps to its own actionable message (R10):
  // retry after fixing the network, wait out GitHub rate limiting, report
  // an invalid manifest, or acknowledge a busy/generic failure.
  for (final (status, expected) in [
    (UpdateCheckStatus.offline, '无法连接更新服务，请检查网络后重试'),
    (UpdateCheckStatus.rateLimited, 'GitHub 限流，请稍后重试'),
    (UpdateCheckStatus.invalid, '更新清单无效，请向开发者反馈'),
    (UpdateCheckStatus.busy, '已有更新任务进行中'),
    (UpdateCheckStatus.failed, '更新检查或安装失败，请稍后重试'),
  ]) {
    testWidgets('check status $status renders its own text', (tester) async {
      await pumpAbout(
        tester,
        service: _StubUpdateService(
          checkResult: UpdateCheckResult(status: status),
        ),
      );

      await tester.tap(find.widgetWithText(FilledButton, '检查更新'));
      await tester.pumpAndSettle();

      expect(find.text(expected), findsOneWidget);
    });
  }

  testWidgets('apply canceled reports cancellation, not generic failure', (
    tester,
  ) async {
    await pumpAbout(
      tester,
      service: _StubUpdateService(
        checkResult: UpdateCheckResult(
          status: UpdateCheckStatus.available,
          release: fakeUpdateRelease(),
        ),
        applyResult: const UpdateApplyResult(
          status: UpdateApplyStatus.canceled,
        ),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, '检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '下载并安装'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(find.text('已取消更新安装'), findsOneWidget);
    expect(find.text('更新检查或安装失败，请稍后重试'), findsNothing);
  });

  testWidgets('apply failed keeps the generic failure text', (tester) async {
    await pumpAbout(
      tester,
      service: _StubUpdateService(
        checkResult: UpdateCheckResult(
          status: UpdateCheckStatus.available,
          release: fakeUpdateRelease(),
        ),
        applyResult: const UpdateApplyResult(
          status: UpdateApplyStatus.failed,
          errorCode: 'install_failed',
        ),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, '检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '下载并安装'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(find.text('更新检查或安装失败，请稍后重试'), findsOneWidget);
  });
}

/// Serves the staged check/apply results — the github-flavoured capability
/// keeps the update controls rendered while the service internals never run.
class _StubUpdateService extends UpdateService {
  _StubUpdateService({required this.checkResult, this.applyResult})
    : super(manifestTransport: _UnusedTransport(), platform: _FdroidPlatform());

  final UpdateCheckResult checkResult;
  final UpdateApplyResult? applyResult;

  @override
  Future<UpdateCapability> capability() async =>
      const UpdateCapability.github();

  @override
  Future<UpdateCheckResult> check({
    UpdateChannel channel = UpdateChannel.stable,
  }) async => checkResult;

  @override
  Future<UpdateApplyResult> apply(
    UpdateRelease release, {
    bool confirmed = false,
  }) async =>
      applyResult ??
      const UpdateApplyResult(status: UpdateApplyStatus.installStarted);
}

UpdateRelease fakeUpdateRelease() =>
    UpdateRelease(manifest: const _FakeUpdateManifest(), rawManifest: const []);

class _FakeUpdateManifest implements UpdateManifestLike {
  const _FakeUpdateManifest();

  @override
  String get repository => 'Lopution/Pixiv-func';
  @override
  String get tag => 'v9.9.9';
  @override
  UpdateChannel get channel => UpdateChannel.stable;
  @override
  UpdateVersionLike get version => const _FakeUpdateVersion('9.9.9');
  @override
  int get versionCode => 999;
  @override
  UpdateReleaseAsset get asset => UpdateReleaseAsset(
    url: Uri.parse('https://example.invalid/app.apk'),
    exactSize: 1,
    sha256: '',
    packageName: 'com.example.pixiv_func',
    signingCertificateSha256: '',
  );
}

class _FakeUpdateVersion implements UpdateVersionLike {
  const _FakeUpdateVersion(this.text);

  final String text;

  @override
  bool get isPrerelease => false;

  @override
  int compareTo(UpdateVersionLike other) => 0;

  @override
  String toString() => text;
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
