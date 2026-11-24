import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:parfait/app/clipboard.dart';
import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/core/logging/crash_log.dart';
import 'package:parfait/core/platform/app_storage_paths.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/core/share/share_service.dart';
import 'package:parfait/core/updater/update_providers.dart';
import 'package:parfait/features/settings/pages/about_settings_page.dart';

import 'helpers/localized_app.dart';
import 'helpers/prompt_host.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/recording_share_service.dart';
import 'helpers/view_size.dart';
import 'helpers/waits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharePayload', () {
    test('each payload shares its title, author and canonical URL', () {
      for (final (payload, url, text) in [
        (
          SharePayload.illust(id: 1234, title: 'A piece', author: 'an artist'),
          'https://www.pixiv.net/artworks/1234',
          'A piece | an artist #Pixiv https://www.pixiv.net/artworks/1234',
        ),
        (
          SharePayload.novel(id: 77, title: 'A story', author: 'a writer'),
          'https://www.pixiv.net/novel/show.php?id=77',
          'A story | a writer #Pixiv https://www.pixiv.net/novel/show.php?id=77',
        ),
        (
          SharePayload.user(id: 42, name: 'tester'),
          'https://www.pixiv.net/users/42',
          'tester | tester #Pixiv https://www.pixiv.net/users/42',
        ),
      ]) {
        expect((payload.url, payload.text), (url, text));
      }
    });
  });

  group('SystemShareService', () {
    test('missing platform support falls back to the clipboard', () async {
      final payload = SharePayload.user(id: 42, name: 'tester');
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      // share_plus has no implementation in the test environment, so the
      // plugin throws and the service must degrade to a clipboard copy
      // instead of surfacing an error.
      final outcome = await const SystemShareService().share(payload);
      expect(outcome, ShareOutcome.copiedToClipboard);
      expect(copied, payload.text);
    });
  });

  group('copyToClipboard', () {
    List<String> mockClipboard({bool fail = false}) {
      final written = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          if (fail) throw PlatformException(code: 'clipboard_unavailable');
          written.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      return written;
    }

    Future<BuildContext> pumpHost(WidgetTester tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          builder: promptHostBuilder,
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      return context;
    }

    testWidgets('copies, confirms with the success haptic and a toast', (
      tester,
    ) async {
      final haptics = recordHaptics();
      final written = mockClipboard();
      final context = await pumpHost(tester);

      await copyToClipboard(context, 'pixiv.net', message: 'Copied');
      await tester.pump();

      expect(written, ['pixiv.net']);
      expect(haptics.roles, [HapticRole.success]);
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('a failed write claims nothing', (tester) async {
      final haptics = recordHaptics();
      mockClipboard(fail: true);
      final context = await pumpHost(tester);

      await expectLater(
        copyToClipboard(context, 'pixiv.net', message: 'Copied'),
        throwsA(isA<PlatformException>()),
      );
      await tester.pump();

      expect(haptics.played, isEmpty);
      expect(find.text('Copied'), findsNothing);
    });
  });

  group('share origin helpers & crash log export', () {
    testWidgets(
      'shareOriginOf and shareOriginAt clip to viewport and fall back to center',
      (tester) async {
        setViewSize(tester, const Size(800, 600));
        late BuildContext clippedCtx;
        late BuildContext offscreenCtx;
        await tester.pumpWidget(
          MaterialApp(
            home: Stack(
              children: [
                Positioned(
                  left: 760,
                  top: 20,
                  width: 80,
                  height: 40,
                  child: Builder(
                    builder: (c) {
                      clippedCtx = c;
                      return const SizedBox.expand();
                    },
                  ),
                ),
                Positioned(
                  left: 900,
                  top: 20,
                  width: 40,
                  height: 40,
                  child: Builder(
                    builder: (c) {
                      offscreenCtx = c;
                      return const SizedBox.expand();
                    },
                  ),
                ),
              ],
            ),
          ),
        );

        expect(shareOriginOf(clippedCtx), const Rect.fromLTWH(760, 20, 40, 40));
        expect(
          shareOriginOf(offscreenCtx),
          const Rect.fromLTWH(399.5, 299.5, 1, 1),
        );
        expect(
          shareOriginAt(clippedCtx, const Offset(950, -20)),
          const Rect.fromLTWH(799, 0, 1, 1),
        );
        expect(
          clampShareOrigin(clippedCtx, const Rect.fromLTWH(-50, -50, 20, 20)),
          const Rect.fromLTWH(399.5, 299.5, 1, 1),
        );
      },
    );

    testWidgets(
      'AboutSettingsPage exports crash log with clipped tile sharePositionOrigin on iPad',
      (tester) async {
        PackageInfo.setMockInitialValues(
          appName: 'Parfait',
          packageName: 'io.github.lopution.parfait',
          version: '1.0.0',
          buildNumber: '1',
          buildSignature: '',
        );
        final tempDir = Directory.systemTemp.createTempSync('parfait_log_');
        final prevPaths = AppStoragePaths.active;
        addTearDown(() {
          AppStoragePaths.setActive(prevPaths);
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        final devPaths = AppStoragePaths.dev(tempDir);
        AppStoragePaths.setActive(devPaths);
        final supportDir = devPaths.supportDir!..createSync(recursive: true);
        final logFile = CrashLog.fileFor(supportDir);
        logFile.parent.createSync(recursive: true);
        logFile.writeAsStringSync('crash-trace');

        final share = RecordingShareService();
        setViewSize(tester, const Size(1024, 768));
        await tester.pumpWidget(
          localizedApp(
            builder: promptHostBuilder,
            overrides: [
              platformCapsProvider.overrideWithValue(
                const PlatformCaps(isIOS: true),
              ),
              updateServiceProvider.overrideWith((_) => Future.error('unused')),
              shareServiceProvider.overrideWithValue(share),
            ],
            home: const AboutSettingsPage(),
          ),
        );
        await tester.pumpAndSettle();

        final tile = find.text('导出日志');
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await pumpIoUntil(tester, () => share.fileShares.isNotEmpty);

        expect(share.fileShares, hasLength(1));
        final exported = share.fileShares.single;
        expect(exported.subject, 'parfait-crash.log');
        expect(exported.files.single.path, CrashLog.fileFor(supportDir).path);
        final origin = exported.origin!;
        expect(origin.isEmpty, isFalse);
        expect(origin.height, lessThan(200));
        expect(
          const Rect.fromLTWH(0, 0, 1024, 768).contains(origin.center),
          isTrue,
        );
      },
    );
  });
}
