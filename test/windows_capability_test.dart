import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/core/auth/account_transfer_service.dart';
import 'package:parfait/core/download/download_destination.dart';
import 'package:parfait/core/download/download_recovery.dart';
import 'package:parfait/core/download/download_request.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/download/resume_anchor.dart';
import 'package:parfait/core/platform/account_transfer_clipboard.dart';
import 'package:parfait/core/platform/android_intent_channel.dart';
import 'package:parfait/core/platform/android_platform_interfaces.dart';
import 'package:parfait/core/platform/desktop_clipboard.dart';
import 'package:parfait/core/platform/desktop_file_sink.dart';
import 'package:parfait/core/platform/intent_router.dart';
import 'package:parfait/core/platform/ios_photo_library.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/core/platform/saf_tree.dart';
import 'package:parfait/core/reverse_image/reverse_image_external.dart';
import 'package:parfait/core/updater/update_platform.dart';

import 'helpers/test_preferences.dart';

const _windows = PlatformCaps(isWindows: true);
const _android = PlatformCaps(isAndroid: true);

ProviderContainer _container(PlatformCaps caps) => ProviderContainer.test(
  overrides: [platformCapsProvider.overrideWithValue(caps)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformCaps selection', () {
    test('each capability picks the platform implementation', () {
      final windows = _container(_windows);
      final android = _container(_android);
      for (final (provider, onWindows, onAndroid) in [
        (
          safTreePickerProvider,
          isA<DesktopDirectoryPicker>(),
          isA<MethodChannelSafTree>(),
        ),
        (
          safDocumentSinkFactoryProvider,
          isA<DesktopSafDocumentSinkFactory>(),
          isA<MethodChannelSafTree>(),
        ),
        (
          transferClipboardProvider,
          isA<FlutterTransferClipboard>(),
          isA<MethodChannelTransferClipboard>(),
        ),
        (
          outboundUrlOpenerProvider,
          isA<UrlLauncherOutboundUrlOpener>(),
          isA<MethodChannelOutboundUrlOpener>(),
        ),
      ]) {
        expect(windows.read(provider), onWindows);
        expect(android.read(provider), onAndroid);
      }
    });

    test('five-platform capability matrix exposes semantic gates', () {
      const capsMatrix = [
        (
          PlatformCaps(isAndroid: true),
          true,
          false,
          false,
          true,
          false,
          false,
          true,
          true,
          false,
          true,
        ),
        (
          PlatformCaps(isIOS: true),
          true,
          true,
          false,
          false,
          true,
          false,
          true,
          true,
          false,
          false,
        ),
        (
          PlatformCaps(isWindows: true),
          false,
          false,
          true,
          false,
          false,
          false,
          true,
          false,
          true,
          false,
        ),
        (
          PlatformCaps(isMacOS: true),
          false,
          true,
          true,
          false,
          false,
          true,
          true,
          true,
          true,
          false,
        ),
        (
          PlatformCaps(isLinux: true),
          false,
          false,
          true,
          false,
          false,
          false,
          false,
          false,
          true,
          false,
        ),
      ];
      for (final c in capsMatrix) {
        final caps = c.$1;
        expect(caps.isMobile, c.$2);
        expect(caps.isApple, c.$3);
        expect(caps.isDesktop, c.$4);
        expect(caps.supportsMediaStore, c.$5);
        expect(caps.supportsPhotoLibrary, c.$6);
        expect(caps.supportsHaptics, c.$2);
        expect(caps.supportsWindowManager, c.$4);
        expect(caps.supportsSystemTray, c.$4);
        expect(caps.supportsSingleInstance, c.$4);
        expect(caps.supportsSecurityScopedBookmarks, c.$7);
        expect(caps.supportsInAppWebView, c.$8);
        expect(caps.supportsCustomSchemeCallback, c.$9);
        expect(caps.supportsLoopbackCallback, c.$10);
        expect(caps.supportsSelfUpdater, c.$11);
        expect(caps.supportsInboundIntents, isTrue);
      }
    });
  });

  group('UnsupportedUpdatePlatform', () {
    test(
      'reports storeManaged so the updater takes the disabled path',
      () async {
        final capability = await const UnsupportedUpdatePlatform().capability();
        expect(capability.storeManaged, isTrue);
        expect(capability.enabled, isFalse);
      },
    );

    test('other verbs fail loudly', () {
      expect(
        () => const UnsupportedUpdatePlatform().deleteApk('x'),
        throwsA(isA<UpdatePlatformException>()),
      );
    });
  });

  group('NoopAndroidIntentSource', () {
    test('reports ignored initial intent and an empty stream', () async {
      const source = NoopAndroidIntentSource();
      expect(await source.readInitial(), isA<IgnoredAndroidIntent>());
      await expectLater(source.onNewIntent, emitsDone);
    });
  });

  group('UrlLauncherOutboundUrlOpener', () {
    test('rejects non-http(s) urls', () {
      expect(
        () => const UrlLauncherOutboundUrlOpener().openExternal('pixiv://x'),
        throwsStateError,
      );
    });
  });

  group('desktop staged file sinks', () {
    late Directory dir;
    late DesktopSafDocumentSinkFactory saf;
    late DesktopFileMediaStoreSession mediaStore;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pixiv_sink_test');
      saf = const DesktopSafDocumentSinkFactory();
      mediaStore = DesktopFileMediaStoreSession(baseDirectory: () async => dir);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('saf sink stages into .part and materialises on close', () async {
      final sink = await saf.create(
        treeUri: dir.path,
        displayName: 'a.png',
        mimeType: 'image/png',
      );
      await sink.write([1, 2, 3]);
      // Pending bytes live in the staged file; the final name must not exist.
      expect(File('${dir.path}/a.png.part').existsSync(), isTrue);
      expect(File('${dir.path}/a.png').existsSync(), isFalse);
      await sink.close();
      expect(File('${dir.path}/a.png').existsSync(), isTrue);
      expect(await File('${dir.path}/a.png').readAsBytes(), [1, 2, 3]);
    });

    test('saf delete removes the staged file and never the final', () async {
      final sink = await saf.create(
        treeUri: dir.path,
        displayName: 'b.png',
        mimeType: 'image/png',
      );
      await sink.write([9]);
      await sink.delete();
      expect(File('${dir.path}/b.png.part').existsSync(), isFalse);
      expect(File('${dir.path}/b.png').existsSync(), isFalse);
    });

    test('mediastore session maps Pictures/<album>, else Parfait, under the '
        'base dir', () async {
      for (final (relativePath, album) in [
        ('Pictures/MyAlbum', 'MyAlbum'),
        (null, 'Parfait'),
      ]) {
        final handle = await mediaStore.begin(
          displayName: 'c.png',
          mimeType: 'image/png',
          relativePath: relativePath,
        );
        await handle.write([4, 5]);
        final uri = await handle.finalize();
        expect(uri.scheme, 'file');
        final file = File('${dir.path}/$album/c.png');
        expect(await file.readAsBytes(), [4, 5], reason: album);
      }
    });

    test('abort removes the staged file', () async {
      final handle = await mediaStore.begin(
        displayName: 'e.png',
        mimeType: 'image/png',
      );
      await handle.write([1]);
      await handle.abort();
      expect(File('${dir.path}/Parfait/e.png.part').existsSync(), isFalse);
      expect(File('${dir.path}/Parfait/e.png').existsSync(), isFalse);
    });

    test('unsafe characters in the display name are sanitized', () async {
      final sink = await saf.create(
        treeUri: dir.path,
        displayName: 'a/b:c.png',
        mimeType: 'image/png',
      );
      await sink.write([1]);
      await sink.close();
      expect(File('${dir.path}/a_b_c.png').existsSync(), isTrue);
    });

    test(
      'saf download detaches preserving .part and resumes appending (D8)',
      () async {
        final factory = DestinationAwareSinkFactory(
          mediaStore: MediaStoreSinkFactory(mediaStore),
          saf: saf,
        );
        final request = DownloadRequest(
          illustId: 1,
          pageIndex: 0,
          url: Uri.parse('https://i.pximg.net/a.png'),
          target: DownloadTarget.illustPage,
        );
        const owner = DownloadOutputOwner(
          ownerId: 'o1',
          jobId: 'j1',
          accountId: 'a1',
        );
        final destination = DownloadDestination.safFolder(dir.path);
        final sink = await factory.beginOwned(
          request,
          'resume.png',
          owner,
          destination: destination,
        );
        await sink.write([1, 2, 3]);

        final anchor = await (sink as ResumableDownloadSink).detach();
        expect(anchor!.kind, ResumeAnchorKind.saf);
        expect(anchor.storedBytes, 3);
        expect(File('${dir.path}/resume.png.part').existsSync(), isTrue);
        expect(File('${dir.path}/resume.png').existsSync(), isFalse);
        // Dead sink: cleanup must not delete the preserved bytes.
        await sink.abort();
        expect(File('${dir.path}/resume.png.part').existsSync(), isTrue);

        final resumed = await factory.resumeOwned(anchor, owner);
        expect(resumed, isA<ResumableDownloadSink>());
        expect((resumed! as ResumableDownloadSink).storedBytes, 3);
        await resumed.write([4, 5]);
        final uri = await resumed.finalize();

        expect(File('${dir.path}/resume.png.part').existsSync(), isFalse);
        expect(await File('${dir.path}/resume.png').readAsBytes(), [
          1,
          2,
          3,
          4,
          5,
        ]);
        expect(uri, contains('resume.png'));
      },
    );

    test(
      'mediastore-path download detaches and resumes by .part path (D8)',
      () async {
        final factory = MediaStoreSinkFactory(mediaStore);
        final request = DownloadRequest(
          illustId: 2,
          pageIndex: 0,
          url: Uri.parse('https://i.pximg.net/b.png'),
          target: DownloadTarget.illustPage,
        );
        const owner = DownloadOutputOwner(
          ownerId: 'o1',
          jobId: 'j2',
          accountId: 'a1',
        );
        final sink = await factory.beginOwned(request, 'album.png', owner);
        await sink.write([7, 8]);

        final anchor = await (sink as ResumableDownloadSink).detach();
        expect(anchor!.kind, ResumeAnchorKind.file);
        expect(anchor.locator, endsWith('.part'));
        expect(anchor.storedBytes, 2);

        final resumed = await factory.resumeOwned(anchor, owner);
        expect((resumed! as ResumableDownloadSink).storedBytes, 2);
        await resumed.write([9]);
        await resumed.finalize();
        expect(await File('${dir.path}/Parfait/album.png').readAsBytes(), [
          7,
          8,
          9,
        ]);
      },
    );

    test('resuming a missing .part is a null refusal', () async {
      final resumed = await saf.resumeSaf(
        uri: '${dir.path}/gone.png.part',
        owner: null,
      );
      expect(resumed, isNull);
      final item = await mediaStore.resumePendingPath(
        '${dir.path}/gone.png.part',
      );
      expect(item, isNull);
    });
  });

  group('FlutterTransferClipboard', () {
    // External boundary mock: the platform clipboard is an in-memory store.
    String? clipboardText;

    setUp(() {
      clipboardText = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            switch (call.method) {
              case 'Clipboard.setData':
                clipboardText = (call.arguments as Map)['text'] as String?;
                return null;
              case 'Clipboard.getData':
                return <String, dynamic>{'text': clipboardText};
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test(
      'clearIfCurrent only clears while the fingerprint still owns it',
      () async {
        final clipboard = FlutterTransferClipboard();
        await clipboard.write('owned', clearAfter: const Duration(minutes: 5));
        final fingerprint = transferClipboardFingerprint('owned');
        expect(await clipboard.clearIfCurrent('wrong'), isFalse);
        final content = await clipboard.read();
        expect((content?.text, content?.fingerprint), ('owned', fingerprint));
        expect(await clipboard.clearIfCurrent(fingerprint), isTrue);
        expect(await clipboard.read(), isNull);
      },
    );

    test('capabilities report no sensitive-mark support', () async {
      final caps = await FlutterTransferClipboard().capabilities();
      expect(caps.sensitiveMarkSupported, isFalse);
    });
  });

  group('reverse-image external result allowlist', () {
    test('only plain https result urls are accepted', () {
      expect(
        () => validateExternalResultUrl(
          Uri.parse('https://saucenao.com/search.php?db=999'),
        ),
        returnsNormally,
      );
      for (final raw in [
        'http://saucenao.com/x',
        'pixiv://illust/1',
        'https://user:pw@host/x',
        'https://host:8443/x',
        'https://host/x#frag',
      ]) {
        expect(
          () => validateExternalResultUrl(Uri.parse(raw)),
          throwsFormatException,
          reason: raw,
        );
      }
    });
  });

  group('multiplatform storage, haptics, and clipboard persistence', () {
    test(
      'sanitizeDesktopFileName handles reserved names, trailing dots/spaces, and control chars',
      () {
        expect(sanitizeDesktopFileName('CON.png'), '_CON.png');
        expect(sanitizeDesktopFileName('nul'), '_nul');
        expect(sanitizeDesktopFileName('com9.txt'), '_com9.txt');
        expect(sanitizeDesktopFileName('LPT1'), '_LPT1');
        expect(sanitizeDesktopFileName('photo.jpg. . '), 'photo.jpg');
        expect(sanitizeDesktopFileName('a<b>c\x07.png'), 'a_b_c_.png');
        expect(sanitizeDesktopFileName('...  '), 'download');
      },
    );

    test(
      'PlatformCaps routes iOS haptics and macOS bookmark providers',
      () async {
        final ios = _container(const PlatformCaps(isIOS: true));
        final macos = _container(const PlatformCaps(isMacOS: true));
        final driver = ios.read(hapticsDriverProvider);
        expect(driver, isA<IosHapticsDriver>());
        expect(
          await driver.capability(),
          const HapticsCapability(
            tier: HapticsTier.predefined,
            systemOff: false,
          ),
        );
        expect(
          macos.read(safTreePickerProvider),
          isA<MacosBookmarkDirectoryPicker>(),
        );
        expect(
          macos.read(safDocumentSinkFactoryProvider),
          isA<MacosBookmarkSafDocumentSinkFactory>(),
        );
      },
    );

    test(
      'IosPhotoLibraryMediaStoreSession stages chunks, commits via channel, and resumes detached .part',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp(
          'parfait_ios_photo_test_',
        );
        addTearDown(() => tempRoot.delete(recursive: true));
        const channel = MethodChannel('parfait/ios_photos_test');
        final recordedCalls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              recordedCalls.add(call);
              return 'ph:///LOCAL-ID-1';
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        final session = IosPhotoLibraryMediaStoreSession(
          channel: channel,
          stagingDirectory: () async => tempRoot,
        );
        final handle =
            await session.begin(
                  displayName: 'CON.png',
                  mimeType: 'image/png',
                  relativePath: 'Pictures/Custom',
                )
                as ResumableMediaStoreHandle;
        await handle.write([1, 2, 3]);
        final locator = await handle.detach();
        expect(File(locator).existsSync(), isTrue);

        final resumed = await session.resumePendingPath(locator);
        expect(resumed, isNotNull);
        expect(resumed!.storedBytes, 3);
        await resumed.handle.write([4, 5]);
        final uri = await resumed.handle.finalize();
        expect(uri.toString(), 'ph:///LOCAL-ID-1');
        expect(recordedCalls.single.method, 'saveImage');
        final args = Map<Object?, Object?>.from(
          recordedCalls.single.arguments as Map,
        );
        expect(args['album'], 'Custom');
        expect(args['displayName'], '_CON.png');
        expect(File(args['path']! as String).existsSync(), isFalse);
      },
    );

    test(
      'MacosBookmarkDirectoryPicker and sink factory require bookmarks and pair startAccess/stopAccess',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp(
          'parfait_macos_bm_test_',
        );
        addTearDown(() => tempRoot.delete(recursive: true));
        const channel = MethodChannel('parfait/macos_bookmarks_test');
        final events = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              events.add(call.method);
              switch (call.method) {
                case 'saveBookmark':
                  return 'bm_token_v1';
                case 'startAccess':
                  return tempRoot.path;
                case 'stopAccess':
                  return null;
              }
              return null;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        final picker = MacosBookmarkDirectoryPicker(
          channel,
          _FakePicker(tempRoot.path),
        );
        final bookmark = await picker.pickTree();
        expect(bookmark, 'bm_token_v1');

        final factory = MacosBookmarkSafDocumentSinkFactory(channel);
        expect(
          () => factory.create(
            treeUri: '',
            displayName: 'a.png',
            mimeType: 'image/png',
          ),
          throwsStateError,
        );
        expect(
          () => factory.resumeSaf(uri: '/raw/path.part'),
          throwsStateError,
        );

        final sink =
            await factory.create(
                  treeUri: bookmark!,
                  displayName: 'sample.png',
                  mimeType: 'image/png',
                )
                as ResumableSafDocument;
        await sink.write([10, 20]);
        final locator = sink.resumeLocator;
        await sink.detachSaf();
        expect(events, ['saveBookmark', 'startAccess', 'stopAccess']);

        final resumed = await factory.resumeSaf(uri: locator);
        expect(resumed, isNotNull);
        expect(resumed!.storedBytes, 2);
        await resumed.sink.write([30]);
        await resumed.sink.close();
        expect(events, [
          'saveBookmark',
          'startAccess',
          'stopAccess',
          'startAccess',
          'stopAccess',
        ]);
        expect(await File('${tempRoot.path}/sample.png').readAsBytes(), [
          10,
          20,
          30,
        ]);
      },
    );

    test(
      'FlutterTransferClipboard sweepExpired clears expired persisted payload across restarts',
      () async {
        installPreferencesForTest(memoryPreferences());
        String? clipboardText;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              switch (call.method) {
                case 'Clipboard.setData':
                  clipboardText = (call.arguments as Map)['text'] as String?;
                  return null;
                case 'Clipboard.getData':
                  return <String, dynamic>{'text': clipboardText};
              }
              return null;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
        });

        var clock = DateTime.utc(2026, 11, 13, 12, 0);
        final prefs = SharedPreferencesAsync();
        final writer = FlutterTransferClipboard(
          preferences: prefs,
          now: () => clock,
        );
        await writer.write(
          'secret-bundle',
          clearAfter: const Duration(minutes: 2),
        );
        expect(clipboardText, 'secret-bundle');

        // Simulating relaunch before expiry leaves clipboard intact.
        clock = clock.add(const Duration(seconds: 30));
        final earlySweeper = FlutterTransferClipboard(
          preferences: prefs,
          now: () => clock,
        );
        expect(await earlySweeper.sweepExpired(), isFalse);
        expect(clipboardText, 'secret-bundle');
        earlySweeper.dispose();

        // Simulating resume after expiry clears owned clipboard content.
        clock = clock.add(const Duration(minutes: 2));
        final lateSweeper = FlutterTransferClipboard(
          preferences: prefs,
          now: () => clock,
        );
        expect(await lateSweeper.sweepExpired(), isTrue);
        expect(clipboardText, '');
      },
    );
  });
}

class _FakePicker implements SafTreePicker {
  const _FakePicker(this.path);

  final String path;

  @override
  Future<String?> pickTree() async => path;
}
