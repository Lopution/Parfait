import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixiv_func/core/updater/update_providers.dart';
import 'package:pixiv_func/core/updater/update_service.dart';
import 'package:pixiv_func/features/settings/settings_page.dart';

void main() {
  testWidgets(
    'F-Droid About explains store updates without an updater button',
    (tester) async {
      final service = UpdateService(
        manifestTransport: _UnusedTransport(),
        platform: _FdroidPlatform(),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            updateServiceProvider.overrideWith((ref) async => service),
          ],
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const AboutSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('此构建由 F-Droid 管理更新。'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '检查更新'), findsNothing);
    },
  );
}

class _FdroidPlatform implements UpdatePlatform {
  @override
  Future<UpdateCapability> capability() async =>
      const UpdateCapability.fdroid();

  @override
  Future<UpdatePlatformInfo> info() => throw StateError('not used');

  @override
  Future<bool> verifyManifestSignature({
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
