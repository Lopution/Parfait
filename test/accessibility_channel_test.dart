import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/platform/accessibility.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelAppAccessibility', () {
    const channel = MethodChannel('parfait/accessibility');
    // The mock handle for an EventChannel is a MethodChannel of the same
    // name: listen/cancel arrive as method calls.
    const eventChannel = MethodChannel('parfait/accessibility/events');
    final calls = <MethodCall>[];
    Object? Function(MethodCall call) reply = (_) => null;

    setUp(() {
      calls.clear();
      reply = (_) => null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return reply(call);
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(channel, null)
        ..setMockMethodCallHandler(eventChannel, null);
    });

    test('isTouchExplorationEnabled reads the flag', () async {
      reply = (_) => true;
      expect(
        await const MethodChannelAppAccessibility().isTouchExplorationEnabled(),
        isTrue,
      );
      expect(calls.single.method, 'getTouchExplorationEnabled');
    });

    test('recommendedTimeoutMillis sends base and content flags', () async {
      reply = (_) => 12000;
      expect(
        await const MethodChannelAppAccessibility().recommendedTimeoutMillis(
          4000,
          AppAccessibility.contentText | AppAccessibility.contentControls,
        ),
        12000,
      );
      final arguments = calls.single.arguments as Map<dynamic, dynamic>;
      expect(arguments['originalTimeoutMs'], 4000);
      expect(arguments['contentFlags'], 5);
    });

    test('recommendedTimeoutMillis falls back to base on null', () async {
      reply = (_) => null;
      expect(
        await const MethodChannelAppAccessibility().recommendedTimeoutMillis(
          4000,
          AppAccessibility.contentText,
        ),
        4000,
      );
    });

    test('touchExplorationChanges maps platform events to bool', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(eventChannel, (call) async {
            if (call.method == 'listen') {
              await TestDefaultBinaryMessengerBinding
                  .instance
                  .defaultBinaryMessenger
                  .handlePlatformMessage(
                    eventChannel.name,
                    const StandardMethodCodec().encodeSuccessEnvelope(true),
                    (_) {},
                  );
            }
            return null;
          });
      expect(
        await const MethodChannelAppAccessibility()
            .touchExplorationChanges()
            .first,
        isTrue,
      );
    });
  });

  group('NoopAppAccessibility', () {
    test('reports no touch exploration and base timeout', () async {
      const driver = NoopAppAccessibility();
      expect(await driver.isTouchExplorationEnabled(), isFalse);
      expect(await driver.recommendedTimeoutMillis(4000, 5), 4000);
      expect(driver.touchExplorationChanges(), emitsDone);
    });
  });
}
