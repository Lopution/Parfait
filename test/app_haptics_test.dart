import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/haptics/app_haptics.dart';
import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/core/settings/app_settings.dart';

import 'helpers/recording_haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('each role reaches the driver with the configured strength', () async {
    final roles = {
      HapticRole.select: AppHaptics.select,
      HapticRole.toggleOn: AppHaptics.toggleOn,
      HapticRole.toggleOff: AppHaptics.toggleOff,
      HapticRole.tick: AppHaptics.tick,
      HapticRole.thresholdOn: AppHaptics.thresholdOn,
      HapticRole.thresholdOff: AppHaptics.thresholdOff,
      HapticRole.longPress: AppHaptics.longPress,
      HapticRole.confirm: AppHaptics.confirm,
      HapticRole.success: AppHaptics.success,
      HapticRole.error: AppHaptics.error,
    };
    expect(roles.keys, unorderedEquals(HapticRole.values));
    for (final MapEntry(key: role, value: fire) in roles.entries) {
      final driver = recordHaptics(strength: HapticStrength.strong);
      fire();
      expect(driver.played, [(role, HapticStrength.strong)]);
    }
  });

  test('off and the unconfigured default play nothing', () {
    final driver = recordHaptics(strength: HapticStrength.off);
    AppHaptics.select();
    AppHaptics.confirm();
    AppHaptics.success();
    AppHaptics.error();
    expect(driver.played, isEmpty);

    AppHaptics.debugReset();
    // Nothing configured: there is no driver to reach, and nothing throws.
    AppHaptics.confirm();
  });

  test('an unreadable strength stays silent', () {
    final driver = RecordingHapticsDriver();
    AppHaptics.configure(
      strength: () => throw StateError('settings not ready'),
      driver: driver,
    );
    addTearDown(AppHaptics.debugReset);
    AppHaptics.confirm();
    expect(driver.played, isEmpty);
  });

  test('roles sharing a lane throttle each other', () async {
    final driver = recordHaptics();
    // Light lane: select, toggles, tick, thresholds.
    AppHaptics.select();
    AppHaptics.toggleOn();
    AppHaptics.tick();
    // Heavy lane: a long-press followed by entering selection mode.
    AppHaptics.longPress();
    AppHaptics.confirm();
    AppHaptics.error();
    // Medium lane is separate.
    AppHaptics.success();
    expect(driver.roles, [
      HapticRole.select,
      HapticRole.longPress,
      HapticRole.success,
    ]);
  });

  test('lanes re-arm after their interval', () async {
    final driver = recordHaptics();
    AppHaptics.tick();
    AppHaptics.tick();
    AppHaptics.success();
    AppHaptics.success();
    AppHaptics.confirm();
    AppHaptics.confirm();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    AppHaptics.tick();
    AppHaptics.success();
    AppHaptics.confirm();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    AppHaptics.success();
    AppHaptics.confirm();
    expect(driver.roles, [
      HapticRole.tick,
      HapticRole.success,
      HapticRole.confirm,
      HapticRole.tick,
      HapticRole.success,
      HapticRole.confirm,
    ]);
  });

  test('preview bypasses throttling and plays at the given strength', () {
    final driver = recordHaptics(strength: HapticStrength.off);
    AppHaptics.preview(HapticStrength.light);
    AppHaptics.preview(HapticStrength.strong);
    AppHaptics.preview(HapticStrength.off);
    expect(driver.played, [
      (HapticRole.confirm, HapticStrength.light),
      (HapticRole.confirm, HapticStrength.strong),
    ]);
  });

  test('a throwing driver never escapes', () {
    AppHaptics.configure(
      strength: () => HapticStrength.standard,
      driver: _ThrowingDriver(),
    );
    addTearDown(AppHaptics.debugReset);
    AppHaptics.confirm();
    AppHaptics.preview(HapticStrength.light);
  });

  group('AndroidHapticsDriver', () {
    const channel = MethodChannel('parfait/haptics');
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
          .setMockMethodCallHandler(channel, null);
    });

    test('play sends wire names', () async {
      const AndroidHapticsDriver().play(
        HapticRole.thresholdOn,
        HapticStrength.light,
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.single.method, 'play');
      expect(calls.single.arguments, {
        'role': 'thresholdOn',
        'strength': 'light',
      });
    });

    test('play swallows platform errors', () async {
      reply = (_) => throw PlatformException(code: 'haptics_failed');
      const AndroidHapticsDriver().play(
        HapticRole.select,
        HapticStrength.standard,
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, hasLength(1));
    });

    test('capability decodes the tier and system switch', () async {
      reply = (_) => {'tier': 'predefined', 'systemOff': true};
      expect(
        await const AndroidHapticsDriver().capability(),
        const HapticsCapability(tier: HapticsTier.predefined, systemOff: true),
      );
    });

    test('capability rejects an unknown answer', () async {
      reply = (_) => {'tier': 'buzz', 'systemOff': false};
      await expectLater(
        const AndroidHapticsDriver().capability(),
        throwsFormatException,
      );
    });
  });
}

class _ThrowingDriver implements HapticsDriver {
  @override
  void play(HapticRole role, HapticStrength strength) =>
      throw StateError('broken');

  @override
  Future<HapticsCapability> capability() => throw StateError('broken');
}
