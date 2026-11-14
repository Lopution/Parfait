import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/auth/account_transfer.dart';
import 'package:parfait/core/platform/account_transfer_clipboard.dart';
import 'package:parfait/core/platform/desktop_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final channel = const MethodChannel(TransferClipboardMethods.channel);
  const sensitiveChannel = MethodChannel(
    DesktopSensitiveClipboardMethods.channel,
  );

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(sensitiveChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('method channel writes a fingerprint and bounded expiry', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return true;
        });
    final clipboard = MethodChannelTransferClipboard(channel);

    await clipboard.write(
      'transfer-payload',
      clearAfter: const Duration(minutes: 5),
    );

    expect(received?.method, TransferClipboardMethods.write);
    final arguments = received!.arguments as Map<Object?, Object?>;
    expect(arguments['text'], 'transfer-payload');
    expect(
      arguments['fingerprint'],
      transferClipboardFingerprint('transfer-payload'),
    );
    expect(arguments['clearAfterMs'], 300000);
  });

  test('method channel read rejects a platform fingerprint mismatch', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return <String, Object?>{
            'text': 'transfer-payload',
            'fingerprint': '0' * 64,
          };
        });

    await expectLater(
      MethodChannelTransferClipboard(channel).read(),
      throwsA(
        isA<AccountTransferException>().having(
          (error) => error.code,
          'code',
          AccountTransferErrorCode.clipboardUnavailable,
        ),
      ),
    );
  });

  test('conditional clear preserves a platform-reported replacement', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => false);

    expect(
      await MethodChannelTransferClipboard(
        channel,
      ).clearIfCurrent(transferClipboardFingerprint('transfer-payload')),
      isFalse,
    );
  });

  test(
    'desktop sensitive clipboard uses native privacy channel and falls back honestly when absent',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final platformCalls = <String>[];
      MethodCall? nativeWrite;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call.method);
        return null;
      });
      messenger.setMockMethodCallHandler(sensitiveChannel, (call) async {
        if (call.method == DesktopSensitiveClipboardMethods.capabilities) {
          return <String, Object?>{'sensitiveMarkSupported': true};
        }
        if (call.method == DesktopSensitiveClipboardMethods.write) {
          nativeWrite = call;
          return true;
        }
        return null;
      });

      final clipboard = FlutterTransferClipboard();
      addTearDown(clipboard.dispose);
      expect((await clipboard.capabilities()).sensitiveMarkSupported, isTrue);
      await clipboard.write(
        'transfer-payload',
        clearAfter: const Duration(minutes: 5),
      );
      expect(nativeWrite?.arguments, <String, Object?>{
        'text': 'transfer-payload',
      });
      expect(platformCalls, isEmpty);

      messenger.setMockMethodCallHandler(sensitiveChannel, (call) async {
        throw PlatformException(code: 'clipboard_unavailable');
      });
      await expectLater(
        clipboard.write('second', clearAfter: const Duration(minutes: 5)),
        throwsA(
          isA<AccountTransferException>().having(
            (e) => e.code,
            'code',
            AccountTransferErrorCode.clipboardUnavailable,
          ),
        ),
      );
      expect(platformCalls, isEmpty);

      messenger.setMockMethodCallHandler(sensitiveChannel, null);
      expect((await clipboard.capabilities()).sensitiveMarkSupported, isFalse);
      await clipboard.write('fallback', clearAfter: const Duration(minutes: 5));
      expect(platformCalls, ['Clipboard.setData']);
    },
  );
}
