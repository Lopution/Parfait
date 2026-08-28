import 'dart:async';

import 'package:flutter/widgets.dart';

/// Coordinates the root double-back-to-exit behaviour (parent PRD R7).
///
/// First back press within the window arms the prompt and reports "show
/// hint"; a second press inside the window reports "exit". The timer never
/// leaks across the window: expiry, explicit disarm and dispose all cancel
/// it, so backgrounding the app or navigating deeper cannot cause a stale
/// exit.
class RootBackCoordinator {
  static const Duration exitWindow = Duration(seconds: 1);

  RootBackCoordinator({this.clock = DateTime.now});

  /// Injectable clock for deterministic tests.
  final DateTime Function() clock;

  Timer? _timer;
  DateTime? _armedAt;

  /// Whether the exit window is currently armed.
  @visibleForTesting
  bool get armed => _armedAt != null;

  /// Handles a root back press.
  ///
  /// Returns [RootBackAction.showExitHint] on the first press (and re-arms),
  /// [RootBackAction.exit] when pressed again inside the window.
  RootBackAction handleBackPress() {
    final armedAt = _armedAt;
    if (armedAt != null && clock().difference(armedAt) <= exitWindow) {
      disarm();
      return RootBackAction.exit;
    }
    disarm();
    _armedAt = clock();
    _timer = Timer(exitWindow, disarm);
    return RootBackAction.showExitHint;
  }

  /// Explicitly disarms (navigation away, app paused, external pop).
  void disarm() {
    _timer?.cancel();
    _timer = null;
    _armedAt = null;
  }

  /// A back gesture must not survive an Android lifecycle transition. This
  /// keeps an interrupted predictive-back gesture or backgrounded activity
  /// from turning a later, unrelated press into an exit.
  void onLifecycleChange(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) disarm();
  }

  /// Nested navigation owns the next back result; clear root exit state when
  /// a child route is pushed so it cannot leak across route boundaries.
  void onRoutePushed() => disarm();

  void dispose() {
    disarm();
  }
}

enum RootBackAction { showExitHint, exit }
