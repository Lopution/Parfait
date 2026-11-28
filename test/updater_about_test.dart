import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/app/widgets/app_progress_bar.dart';
import 'package:parfait/core/updater/update_download.dart';
import 'package:parfait/core/updater/update_providers.dart';
import 'package:parfait/core/updater/update_service.dart';
import 'package:parfait/features/settings/settings_page.dart';

import 'helpers/prompt_host.dart';
import 'helpers/updater_fakes.dart';
import 'helpers/localized_app.dart';

void main() {
  Future<void> pumpAbout(
    WidgetTester tester, {
    UpdateService? service,
    bool settle = true,
  }) async {
    final effectiveService =
        service ??
        UpdateService(
          manifestTransport: UnusedManifestTransport(),
          platform: FakeUpdatePlatform(
            capability: const UpdateCapability.fdroid(),
          ),
        );
    // Tall enough that the update block below the about rows is built.
    tester.view.physicalSize = const Size(800, 3000);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      localizedApp(
        overrides: [
          updateServiceProvider.overrideWith((ref) async => effectiveService),
        ],
        builder: promptHostBuilder,
        home: const AboutSettingsPage(),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  testWidgets(
    'F-Droid About explains store updates without an updater button',
    (tester) async {
      await pumpAbout(tester);

      expect(find.text('此构建由 F-Droid 管理更新。'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '检查更新'), findsNothing);
    },
  );

  testWidgets('apply canceled reports cancellation, failed the generic text', (
    tester,
  ) async {
    for (final (result, shown, hidden) in [
      (
        const UpdateApplyResult(status: UpdateApplyStatus.canceled),
        '已取消更新安装',
        '更新检查或安装失败，请稍后重试',
      ),
      (
        const UpdateApplyResult(
          status: UpdateApplyStatus.failed,
          errorCode: 'install_failed',
        ),
        '更新检查或安装失败，请稍后重试',
        '已取消更新安装',
      ),
    ]) {
      // A fresh tree and provider scope per row.
      await tester.pumpWidget(const SizedBox());
      await pumpAbout(
        tester,
        service: _StubUpdateService(
          checkResult: UpdateCheckResult(
            status: UpdateCheckStatus.available,
            release: fakeUpdateRelease(),
          ),
          applyResult: result,
        ),
      );

      await tester.tap(find.widgetWithText(FilledButton, '检查更新'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '下载并安装'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();

      expect(find.text(shown), findsOneWidget);
      expect(find.text(hidden), findsNothing);
    }
  });

  testWidgets(
    'in-flight update download keeps progress and cancel button across About re-entry',
    (tester) async {
      final service = _RememberedCheckUpdateService(
        UpdateCheckResult(
          status: UpdateCheckStatus.available,
          release: fakeUpdateRelease(),
        ),
        _HangingUpdateDownloader(),
      );
      await pumpAbout(tester, service: service);
      await tester.tap(find.widgetWithText(FilledButton, '下载并安装'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pump();
      await tester.pump();
      expect(find.text('正在下载并验证…'), findsOneWidget);
      expect(find.byType(AppProgressBar), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await pumpAbout(tester, service: service, settle: false);
      expect(find.text('正在下载并验证…'), findsOneWidget);
      expect(find.byType(AppProgressBar), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '取消'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '下载并安装'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.text('已取消更新安装'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '下载并安装'), findsOneWidget);
    },
  );
}

/// Serves the staged check/apply results — the github-flavoured capability
/// keeps the update controls rendered while the service internals never run.
class _StubUpdateService extends UpdateService {
  _StubUpdateService({required this.checkResult, this.applyResult})
    : super(
        manifestTransport: UnusedManifestTransport(),
        platform: FakeUpdatePlatform(),
      );

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

class _HangingUpdateDownloader implements UpdateApkDownloader {
  final _pending = Completer<UpdateApplyResult>();
  @override
  Future<UpdateApplyResult> recover(UpdateRelease release) async =>
      const UpdateApplyResult(
        status: UpdateApplyStatus.failed,
        errorCode: 'no_recoverable_update',
      );
  @override
  Future<UpdateApplyResult> download(UpdateRelease release) => _pending.future;
  @override
  Future<bool> cleanup(String path) async => true;
  @override
  Future<void> cancel() async {
    if (!_pending.isCompleted) {
      _pending.complete(
        const UpdateApplyResult(status: UpdateApplyStatus.canceled),
      );
    }
  }
}

class _RememberedCheckUpdateService extends UpdateService {
  _RememberedCheckUpdateService(this._remembered, UpdateApkDownloader d)
    : super(
        manifestTransport: UnusedManifestTransport(),
        platform: FakeUpdatePlatform(),
        downloader: d,
      );
  final UpdateCheckResult _remembered;
  @override
  UpdateCheckResult? get lastCheck => _remembered;
}
