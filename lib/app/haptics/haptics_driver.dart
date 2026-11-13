import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/platform/platform_caps.dart';
import '../../core/settings/app_settings.dart';

/// What a haptic means. The role → effect mapping lives only in the Android
/// planner (`HapticPlanner.kt`); the wire names are the enum names.
enum HapticRole {
  select,
  toggleOn,
  toggleOff,
  tick,
  thresholdOn,
  thresholdOff,
  longPress,
  confirm,
  success,
  error,
}

/// How the device plays haptics, best first (see `HapticTier` on Android).
enum HapticsTier { composition, predefined, system, none }

@immutable
final class HapticsCapability {
  const HapticsCapability({required this.tier, required this.systemOff});

  static const none = HapticsCapability(
    tier: HapticsTier.none,
    systemOff: false,
  );

  final HapticsTier tier;

  /// The system "touch feedback" switch is off; app haptics stay silent.
  final bool systemOff;

  @override
  bool operator ==(Object other) =>
      other is HapticsCapability &&
      other.tier == tier &&
      other.systemOff == systemOff;

  @override
  int get hashCode => Object.hash(tier, systemOff);

  @override
  String toString() => 'HapticsCapability($tier, systemOff: $systemOff)';
}

/// Platform boundary of [AppHaptics]; tests inject a recording driver.
abstract interface class HapticsDriver {
  /// Fire-and-forget: failures are logged, never thrown — haptics are a
  /// redundant channel and must not break the visual feedback path.
  void play(HapticRole role, HapticStrength strength);

  /// Throws when the platform cannot answer.
  Future<HapticsCapability> capability();
}

final class AndroidHapticsDriver implements HapticsDriver {
  const AndroidHapticsDriver([
    this._channel = const MethodChannel('parfait/haptics'),
  ]);

  final MethodChannel _channel;

  @override
  void play(HapticRole role, HapticStrength strength) {
    unawaited(
      _channel
          .invokeMethod<void>('play', {
            'role': role.name,
            'strength': strength.name,
          })
          .catchError((Object error) {
            log('haptics: play ${role.name} failed: $error');
          }),
    );
  }

  @override
  Future<HapticsCapability> capability() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('capabilities');
    final tierName = raw?['tier'];
    final systemOff = raw?['systemOff'];
    final tier = HapticsTier.values.where((t) => t.name == tierName);
    if (tier.isEmpty || systemOff is! bool) {
      throw FormatException('haptics: unexpected capabilities $raw');
    }
    return HapticsCapability(tier: tier.single, systemOff: systemOff);
  }
}

/// iOS haptics backed by Flutter's `HapticFeedback` (UIKit feedback
/// generators).
final class IosHapticsDriver implements HapticsDriver {
  const IosHapticsDriver();

  @override
  void play(HapticRole role, HapticStrength strength) {
    if (strength == HapticStrength.off) return;
    final Future<void> call = switch (role) {
      HapticRole.select ||
      HapticRole.tick ||
      HapticRole.toggleOff ||
      HapticRole.thresholdOff => HapticFeedback.selectionClick(),
      HapticRole.toggleOn ||
      HapticRole.thresholdOn ||
      HapticRole.confirm => switch (strength) {
        HapticStrength.light => HapticFeedback.lightImpact(),
        HapticStrength.standard => HapticFeedback.mediumImpact(),
        HapticStrength.strong => HapticFeedback.heavyImpact(),
        HapticStrength.off => Future<void>.value(),
      },
      HapticRole.longPress =>
        strength == HapticStrength.strong
            ? HapticFeedback.heavyImpact()
            : HapticFeedback.mediumImpact(),
      HapticRole.success =>
        strength == HapticStrength.light
            ? HapticFeedback.lightImpact()
            : HapticFeedback.mediumImpact(),
      HapticRole.error =>
        strength == HapticStrength.light
            ? HapticFeedback.mediumImpact()
            : HapticFeedback.heavyImpact(),
    };
    unawaited(
      call.catchError((Object error) {
        log('haptics: iOS play ${role.name} failed: $error');
      }),
    );
  }

  @override
  Future<HapticsCapability> capability() async =>
      const HapticsCapability(tier: HapticsTier.predefined, systemOff: false);
}

/// Desktop: no haptics hardware.
final class NoHapticsDriver implements HapticsDriver {
  const NoHapticsDriver();

  @override
  void play(HapticRole role, HapticStrength strength) {}

  @override
  Future<HapticsCapability> capability() async => HapticsCapability.none;
}

final hapticsDriverProvider = Provider<HapticsDriver>((ref) {
  final caps = ref.watch(platformCapsProvider);
  if (caps.isAndroid) return const AndroidHapticsDriver();
  if (caps.isIOS) return const IosHapticsDriver();
  return const NoHapticsDriver();
});

final hapticsCapabilityProvider = FutureProvider<HapticsCapability>(
  (ref) => ref.watch(hapticsDriverProvider).capability(),
);
