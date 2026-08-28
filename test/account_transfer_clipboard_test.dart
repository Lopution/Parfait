import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account_transfer.dart';
import 'package:pixiv_func/core/platform/account_transfer_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final channel = const MethodChannel(TransferClipboardMethods.channel);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
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
      throwsA(isA<AccountTransferException>().having(
        (error) => error.code,
        'code',
        AccountTransferErrorCode.clipboardUnavailable,
      )),
    );
  });

  test('conditional clear preserves a platform-reported replacement', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => false);

    expect(
      await MethodChannelTransferClipboard(channel).clearIfCurrent(
        transferClipboardFingerprint('transfer-payload'),
      ),
      isFalse,
    );
  });
}
