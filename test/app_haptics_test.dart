import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/app/haptics/app_haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final hapticCalls = <String>[];

  setUp(() {
    AppHaptics.debugReset();
    hapticCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            hapticCalls.add(call.arguments as String);
          }
          return null;
        });
  });

  tearDown(() {
    AppHaptics.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('roles map to their platform levels', () async {
    AppHaptics.configure(isEnabled: () => true);
    AppHaptics.select();
    AppHaptics.confirm();
    AppHaptics.success();
    AppHaptics.error();
    await Future<void>.delayed(Duration.zero);
    expect(hapticCalls, [
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.heavyImpact',
      'HapticFeedbackType.mediumImpact',
      // error() shares the heavy channel with confirm() — inside the 120ms
      // throttle window it is dropped (per-level throttling).
    ]);
    expect(hapticCalls, hasLength(3));
  });

  test('error fires on its own once the heavy window has passed', () async {
    AppHaptics.configure(isEnabled: () => true);
    AppHaptics.error();
    await Future<void>.delayed(Duration.zero);
    expect(hapticCalls, ['HapticFeedbackType.heavyImpact']);
  });

  test('disabled setting suppresses every role', () async {
    AppHaptics.configure(isEnabled: () => false);
    AppHaptics.select();
    AppHaptics.confirm();
    AppHaptics.success();
    AppHaptics.error();
    await Future<void>.delayed(Duration.zero);
    expect(hapticCalls, isEmpty);
  });

  test('select throttles within 50ms and fires again after', () async {
    AppHaptics.configure(isEnabled: () => true);
    AppHaptics.select();
    AppHaptics.select();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    AppHaptics.select();
    await Future<void>.delayed(Duration.zero);
    expect(hapticCalls, [
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.selectionClick',
    ]);
  });

  test('success throttles within 80ms on its own channel', () async {
    AppHaptics.configure(isEnabled: () => true);
    AppHaptics.success();
    AppHaptics.success();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    AppHaptics.success();
    await Future<void>.delayed(Duration.zero);
    expect(hapticCalls, [
      'HapticFeedbackType.mediumImpact',
      'HapticFeedbackType.mediumImpact',
    ]);
  });

  test('missing platform support is swallowed silently', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          throw MissingPluginException('no haptics');
        });
    AppHaptics.configure(isEnabled: () => true);
    AppHaptics.select();
    AppHaptics.confirm();
    AppHaptics.success();
    AppHaptics.error();
    await Future<void>.delayed(Duration.zero);
    // No exception escapes; the haptic call is simply dropped.
  });
}
