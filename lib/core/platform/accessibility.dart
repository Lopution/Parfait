import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'platform_caps.dart';

abstract final class _AccessibilityMethods {
  static const channel = 'parfait/accessibility';
  static const events = 'parfait/accessibility/events';
  static const getTouchExplorationEnabled = 'getTouchExplorationEnabled';
  static const recommendedTimeoutMillis = 'recommendedTimeoutMillis';
}

/// Real touch-exploration state plus the system's recommended UI timeout.
///
/// The engine's `accessibleNavigation` flag is unusable as "is a screen
/// reader running": `AccessibilityBridge.createAccessibilityNodeInfo` sets
/// it when ANY assistive service queries a node — including ad-skipping
/// tools like GKD — and nothing resets it short of turning the service off.
/// Native `AccessibilityManager.isTouchExplorationEnabled` is the signal
/// Material components gate on.
abstract interface class AppAccessibility {
  /// `AccessibilityManager.FLAG_CONTENT_TEXT`: the prompt carries a message.
  static const contentText = 1;

  /// `AccessibilityManager.FLAG_CONTENT_CONTROLS`: the prompt has an action.
  static const contentControls = 4;

  Future<bool> isTouchExplorationEnabled();

  /// Current value first, then every state change.
  Stream<bool> touchExplorationChanges();

  /// `getRecommendedTimeoutMillis`: the system's dwell time scaled by the
  /// user's "time to take action" accessibility setting.
  Future<int> recommendedTimeoutMillis(int baseMs, int contentFlags);
}

class MethodChannelAppAccessibility implements AppAccessibility {
  const MethodChannelAppAccessibility([
    this._methodChannel = const MethodChannel(_AccessibilityMethods.channel),
    this._eventChannel = const EventChannel(_AccessibilityMethods.events),
  ]);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  @override
  Future<bool> isTouchExplorationEnabled() async =>
      await _methodChannel.invokeMethod<bool>(
        _AccessibilityMethods.getTouchExplorationEnabled,
      ) ??
      false;

  @override
  Stream<bool> touchExplorationChanges() =>
      _eventChannel.receiveBroadcastStream().map((event) => event == true);

  @override
  Future<int> recommendedTimeoutMillis(int baseMs, int contentFlags) async =>
      await _methodChannel.invokeMethod<int>(
        _AccessibilityMethods.recommendedTimeoutMillis,
        {'originalTimeoutMs': baseMs, 'contentFlags': contentFlags},
      ) ??
      baseMs;
}

/// Desktop and test fallback: no touch exploration, no timeout scaling.
class NoopAppAccessibility implements AppAccessibility {
  const NoopAppAccessibility();

  @override
  Future<bool> isTouchExplorationEnabled() async => false;

  @override
  Stream<bool> touchExplorationChanges() => const Stream.empty();

  @override
  Future<int> recommendedTimeoutMillis(int baseMs, int contentFlags) async =>
      baseMs;
}

/// Android-only capability; other platforms get the no-op driver. On iOS the
/// engine's own `accessibleNavigation` already tracks VoiceOver correctly.
final appAccessibilityProvider = Provider<AppAccessibility>(
  (ref) => ref.watch(platformCapsProvider).isAndroid
      ? const MethodChannelAppAccessibility()
      : const NoopAppAccessibility(),
);

/// Live touch-exploration state. Emits nothing until Android reports the
/// current flag, so readers fall back to the engine value for the first
/// frames — see the root MediaQuery override.
final touchExplorationProvider = StreamProvider<bool>(
  (ref) => ref.watch(appAccessibilityProvider).touchExplorationChanges(),
);
