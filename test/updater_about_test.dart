import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parfait/core/settings/shared_preferences.dart';
import 'package:parfait/core/updater/update_providers.dart';
import 'package:parfait/core/updater/update_service.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';

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
          builder: promptHostBuilder,
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
          builder: promptHostBuilder,
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

  testWidgets('About surfaces the remembered check result before any tap', (
    tester,
  ) async {
    await pumpAbout(
      tester,
      service: _StubUpdateService(
        checkResult: const UpdateCheckResult(
          status: UpdateCheckStatus.noUpdate,
        ),
        lastCheckResult: UpdateCheckResult(
          status: UpdateCheckStatus.available,
          release: fakeUpdateRelease(),
        ),
      ),
    );

    // The auto-check ran at startup; the section renders its remembered
    // result without a manual 检查更新 tap.
    expect(find.text('发现新版本：9.9.9'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '下载并安装'), findsOneWidget);
  });

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
  _StubUpdateService({
    required this.checkResult,
    this.applyResult,
    this.lastCheckResult,
  }) : super(
         manifestTransport: _UnusedTransport(),
         platform: _FdroidPlatform(),
       );

  final UpdateCheckResult checkResult;
  final UpdateApplyResult? applyResult;
  final UpdateCheckResult? lastCheckResult;

  @override
  UpdateCheckResult? get lastCheck => lastCheckResult;

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
  String get repository => 'Lopution/Parfait';
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
    packageName: 'com.example.parfait',
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
