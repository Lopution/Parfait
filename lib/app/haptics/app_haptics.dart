import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Sole haptic-feedback owner for the app (roadmap §5.6).
///
/// Feature code must never call [HapticFeedback] directly — and must never
/// name a vibration level either. Callers express the *role* of the action
/// ([select], [confirm], [success], [error]); the mapping to a
/// `HapticFeedback` level plus the per-level throttle lives only here, so
/// W6/W7-class consumers cannot fork their own intensity vocabulary.
///
/// The enabled reader is injected once per app build by `PixivFuncApp` via
/// [configure]; keeping this class free of Riverpod lets non-widget layers
/// trigger haptics too.
abstract final class AppHaptics {
  static bool Function() _isEnabled = () => true;

  static DateTime _lastSelection = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime _lastMedium = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime _lastHeavy = DateTime.fromMillisecondsSinceEpoch(0);

  /// Minimum interval between two selection-level haptics.
  static const Duration selectionInterval = Duration(milliseconds: 50);

  /// Minimum interval between two medium-level haptics.
  static const Duration mediumInterval = Duration(milliseconds: 80);

  /// Minimum interval between two heavy-level haptics.
  static const Duration heavyInterval = Duration(milliseconds: 120);

  /// Installs the enabled reader (bound to the persisted haptics setting).
  /// Called from `PixivFuncApp.build`; idempotent.
  static void configure({required bool Function() isEnabled}) {
    _isEnabled = isEnabled;
  }

  /// Light tick: selection toggles, mode exits, copy-to-clipboard.
  static void select() {
    _fire(
      kind: _HapticKind.selection,
      action: HapticFeedback.selectionClick,
      interval: selectionInterval,
    );
  }

  /// Distinct vibration: entering a management/selection mode, opening a
  /// destructive or batched action surface.
  static void confirm() {
    _fire(
      kind: _HapticKind.heavy,
      action: HapticFeedback.heavyImpact,
      interval: heavyInterval,
    );
  }

  /// Completion pulse: a save/download/share submission was accepted.
  static void success() {
    _fire(
      kind: _HapticKind.medium,
      action: HapticFeedback.mediumImpact,
      interval: mediumInterval,
    );
  }

  /// Failure vibration: the action the user just attempted did not land.
  static void error() {
    _fire(
      kind: _HapticKind.heavy,
      action: HapticFeedback.heavyImpact,
      interval: heavyInterval,
    );
  }

  static void _fire({
    required _HapticKind kind,
    required Future<void> Function() action,
    required Duration interval,
  }) {
    if (!_isEnabled()) return;
    final now = DateTime.now();
    // Throttling is per physical level, not per role: `confirm` and `error`
    // share the heavy channel so back-to-back vibrations of the same
    // intensity never stack within the window.
    final last = switch (kind) {
      _HapticKind.selection => _lastSelection,
      _HapticKind.medium => _lastMedium,
      _HapticKind.heavy => _lastHeavy,
    };
    if (now.difference(last) < interval) return;
    switch (kind) {
      case _HapticKind.selection:
        _lastSelection = now;
      case _HapticKind.medium:
        _lastMedium = now;
      case _HapticKind.heavy:
        _lastHeavy = now;
    }
    // Platforms without haptics (desktop, missing plugin) must never break
    // the visual feedback path — haptics are a redundant channel, so both
    // sync throws and async platform errors are swallowed here.
    unawaited(
      action().catchError((Object _) {
        // ignore — see above
      }),
    );
  }

  /// Test hook: restores the default enabled reader and clears throttling
  /// timestamps so tests start from a clean slate.
  @visibleForTesting
  static void debugReset() {
    _isEnabled = () => true;
    _lastSelection = DateTime.fromMillisecondsSinceEpoch(0);
    _lastMedium = DateTime.fromMillisecondsSinceEpoch(0);
    _lastHeavy = DateTime.fromMillisecondsSinceEpoch(0);
  }
}

enum _HapticKind { selection, medium, heavy }
