import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pixiv_func/core/auth/account_transfer_service.dart';
import 'package:pixiv_func/core/platform/account_transfer_clipboard.dart';
import 'package:pixiv_func/core/platform/android_intent_channel.dart';
import 'package:pixiv_func/core/platform/desktop_clipboard.dart';
import 'package:pixiv_func/core/platform/desktop_file_sink.dart';
import 'package:pixiv_func/core/platform/intent_router.dart';
import 'package:pixiv_func/core/platform/platform_caps.dart';
import 'package:pixiv_func/core/platform/saf_tree.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_external.dart';
import 'package:pixiv_func/core/updater/update_platform.dart';

const _windows = PlatformCaps(isWindows: true);
const _android = PlatformCaps(isAndroid: true);

ProviderContainer _container(PlatformCaps caps) => ProviderContainer(
  overrides: [platformCapsProvider.overrideWithValue(caps)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformCaps selection', () {
    test('saf picker and sink factory follow the platform', () {
      final windows = _container(_windows);
      expect(
        windows.read(safTreePickerProvider),
        isA<DesktopDirectoryPicker>(),
      );
      expect(
        windows.read(safDocumentSinkFactoryProvider),
        isA<DesktopSafDocumentSinkFactory>(),
      );

      final android = _container(_android);
      expect(android.read(safTreePickerProvider), isA<MethodChannelSafTree>());
      expect(
        android.read(safDocumentSinkFactoryProvider),
        isA<MethodChannelSafTree>(),
      );
    });

    test('clipboard picks the platform implementation', () {
      expect(
        _container(_windows).read(transferClipboardProvider),
        isA<FlutterTransferClipboard>(),
      );
      expect(
        _container(_android).read(transferClipboardProvider),
        isA<MethodChannelTransferClipboard>(),
      );
    });

    test('outbound url opener follows the platform', () {
      expect(
        _container(_windows).read(outboundUrlOpenerProvider),
        isA<UrlLauncherOutboundUrlOpener>(),
      );
      expect(
        _container(_android).read(outboundUrlOpenerProvider),
        isA<MethodChannelOutboundUrlOpener>(),
      );
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

    test(
      'mediastore session maps Pictures/<album> under the base dir',
      () async {
        final handle = await mediaStore.begin(
          displayName: 'c.png',
          mimeType: 'image/png',
          relativePath: 'Pictures/MyAlbum',
        );
        await handle.write([4, 5]);
        final uri = await handle.finalize();
        expect(uri.scheme, 'file');
        final file = File('${dir.path}/MyAlbum/c.png');
        expect(file.existsSync(), isTrue);
        expect(await file.readAsBytes(), [4, 5]);
      },
    );

    test('default album lands under <base>/PixivFunc', () async {
      final handle = await mediaStore.begin(
        displayName: 'd.png',
        mimeType: 'image/png',
      );
      await handle.write([1]);
      await handle.finalize();
      expect(File('${dir.path}/PixivFunc/d.png').existsSync(), isTrue);
    });

    test('abort removes the staged file', () async {
      final handle = await mediaStore.begin(
        displayName: 'e.png',
        mimeType: 'image/png',
      );
      await handle.write([1]);
      await handle.abort();
      expect(File('${dir.path}/PixivFunc/e.png.part').existsSync(), isFalse);
      expect(File('${dir.path}/PixivFunc/e.png').existsSync(), isFalse);
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

    test('write/read round-trips with a fingerprint', () async {
      final clipboard = FlutterTransferClipboard();
      await clipboard.write('hello', clearAfter: const Duration(minutes: 5));
      final content = await clipboard.read();
      expect(content?.text, 'hello');
      expect(content?.fingerprint, transferClipboardFingerprint('hello'));
    });

    test(
      'clearIfCurrent only clears while the fingerprint still owns it',
      () async {
        final clipboard = FlutterTransferClipboard();
        await clipboard.write('owned', clearAfter: const Duration(minutes: 5));
        expect(await clipboard.clearIfCurrent('wrong'), isFalse);
        expect((await clipboard.read())?.text, 'owned');
        final fingerprint = transferClipboardFingerprint('owned');
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
    test('plain https result urls are accepted', () {
      expect(
        () => validateExternalResultUrl(
          Uri.parse('https://saucenao.com/search.php?db=999'),
        ),
        returnsNormally,
      );
    });

    test('non-https and credential/port/fragment urls are rejected', () {
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
}
