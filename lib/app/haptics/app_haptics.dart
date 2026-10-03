import 'package:flutter/foundation.dart';

import '../../core/settings/app_settings.dart';
import 'haptics_driver.dart';

/// Sole haptic-feedback owner for the app (roadmap §5.6).
///
/// Feature code never calls a platform haptic API and never names a
/// vibration level: callers express the *role* of the moment, and the
/// role → effect mapping lives only in the Android planner. Haptics follow
/// the Android principle "confirm a state change caused by the user" —
/// navigation and high-frequency events (scrolling, zooming) stay silent.
///
/// The strength reader and the platform driver are injected once per app
/// build by `ParfaitApp` via [configure]; keeping this class free of
/// Riverpod lets non-widget layers trigger haptics too.
abstract final class AppHaptics {
  static HapticStrength Function() _strength = _offUntilConfigured;
  static HapticsDriver _driver = const NoHapticsDriver();
  static final Map<_Lane, DateTime> _lastFired = {};

  /// Minimum interval between two light-lane haptics (also caps slider
  /// ticks at 20 per second — primitives need ≥ 50 ms to stay distinct).
  static const Duration lightInterval = Duration(milliseconds: 50);

  /// Minimum interval between two medium-lane haptics.
  static const Duration mediumInterval = Duration(milliseconds: 80);

  /// Minimum interval between two heavy-lane haptics.
  static const Duration heavyInterval = Duration(milliseconds: 120);

  static HapticStrength _offUntilConfigured() => HapticStrength.off;

  /// Installs the strength reader (bound to the persisted setting) and the
  /// platform driver. Called from `ParfaitApp.build`; idempotent.
  static void configure({
    required HapticStrength Function() strength,
    required HapticsDriver driver,
  }) {
    _strength = strength;
    _driver = driver;
  }

  /// Picking one option among several: radio, segmented button, single
  /// choice chip, toggling an item in selection mode, undoing a bookmark.
  static void select() => _fire(HapticRole.select);

  /// A switch or multi-select chip turned on.
  static void toggleOn() => _fire(HapticRole.toggleOn);

  /// A switch or multi-select chip turned off.
  static void toggleOff() => _fire(HapticRole.toggleOff);

  /// A slider crossed one division.
  static void tick() => _fire(HapticRole.tick);

  /// A drag crossed the point where releasing would act (refresh, dismiss).
  static void thresholdOn() => _fire(HapticRole.thresholdOn);

  /// A drag went back across that point.
  static void thresholdOff() => _fire(HapticRole.thresholdOff);

  /// An app long-press action opened (action sheet, menu).
  static void longPress() => _fire(HapticRole.longPress);

  /// Entering a management/selection mode, opening a batched or destructive
  /// action surface.
  static void confirm() => _fire(HapticRole.confirm);

  /// The submitted action landed (save, download, bookmark, copy).
  static void success() => _fire(HapticRole.success);

  /// The action the user just attempted did not land.
  static void error() => _fire(HapticRole.error);

  /// Settings preview: plays [confirm] at [strength], bypassing throttling.
  static void preview(HapticStrength strength) {
    if (strength == HapticStrength.off) return;
    _play(HapticRole.confirm, strength);
  }

  static void _fire(HapticRole role) {
    HapticStrength strength;
    try {
      strength = _strength();
    } catch (error) {
      // An unreadable setting must not vibrate against the user's choice.
      debugPrint('haptics: strength unreadable, staying silent: $error');
      return;
    }
    if (strength == HapticStrength.off) return;
    final lane = _laneOf(role);
    final now = DateTime.now();
    final last = _lastFired[lane];
    // Throttling is per lane, not per role: a long-press immediately
    // followed by entering selection mode vibrates once.
    if (last != null && now.difference(last) < lane.interval) return;
    _lastFired[lane] = now;
    _play(role, strength);
  }

  static void _play(HapticRole role, HapticStrength strength) {
    try {
      _driver.play(role, strength);
    } catch (error) {
      // Haptics are a redundant channel; a broken driver must never reach
      // the visual feedback path.
      debugPrint('haptics: driver threw on ${role.name}: $error');
    }
  }

  static _Lane _laneOf(HapticRole role) => switch (role) {
    HapticRole.select ||
    HapticRole.toggleOn ||
    HapticRole.toggleOff ||
    HapticRole.tick ||
    HapticRole.thresholdOn ||
    HapticRole.thresholdOff => _Lane.light,
    HapticRole.success => _Lane.medium,
    HapticRole.longPress ||
    HapticRole.confirm ||
    HapticRole.error => _Lane.heavy,
  };

  /// Test hook: silent until configured again, throttling cleared.
  @visibleForTesting
  static void debugReset() {
    _strength = _offUntilConfigured;
    _driver = const NoHapticsDriver();
    _lastFired.clear();
  }
}

enum _Lane {
  light(AppHaptics.lightInterval),
  medium(AppHaptics.mediumInterval),
  heavy(AppHaptics.heavyInterval);

  const _Lane(this.interval);

  final Duration interval;
}
