import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/platform/root_back_coordinator.dart';

void main() {
  group('RootBackCoordinator', () {
    test('first press arms and shows the hint, second press exits', () {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final coordinator = RootBackCoordinator(clock: () => now);

      expect(coordinator.handleBackPress(), RootBackAction.showExitHint);
      expect(coordinator.armed, isTrue);

      now = now.add(const Duration(milliseconds: 500));
      expect(coordinator.handleBackPress(), RootBackAction.exit);
      expect(coordinator.armed, isFalse);

      coordinator.dispose();
    });

    test('press after the window expired re-arms instead of exiting', () {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final coordinator = RootBackCoordinator(clock: () => now);

      coordinator.handleBackPress();
      now = now.add(const Duration(milliseconds: 1100));
      expect(coordinator.handleBackPress(), RootBackAction.showExitHint);

      coordinator.dispose();
    });

    test('exactly at the window boundary still exits', () {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final coordinator = RootBackCoordinator(clock: () => now);

      coordinator.handleBackPress();
      now = now.add(RootBackCoordinator.exitWindow);
      expect(coordinator.handleBackPress(), RootBackAction.exit);

      coordinator.dispose();
    });

    test('disarm cancels the pending exit window', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      var clockNow = now;
      final coordinator = RootBackCoordinator(clock: () => clockNow);

      coordinator.handleBackPress();
      coordinator.disarm();
      expect(coordinator.armed, isFalse);

      // Even after real timer expiry the coordinator stays disarmed.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      clockNow = now.add(const Duration(seconds: 5));
      expect(coordinator.handleBackPress(), RootBackAction.showExitHint);

      coordinator.dispose();
    });

    test('real timer expiry rearms the window', () async {
      var now = DateTime.now();
      final coordinator = RootBackCoordinator(clock: () => now);

      expect(coordinator.handleBackPress(), RootBackAction.showExitHint);
      await Future<void>.delayed(
        RootBackCoordinator.exitWindow + const Duration(milliseconds: 50),
      );
      now = DateTime.now();
      expect(coordinator.armed, isFalse);
      expect(coordinator.handleBackPress(), RootBackAction.showExitHint);

      coordinator.dispose();
    });

    test('dispose never leaves a pending timer', () async {
      final coordinator = RootBackCoordinator();
      coordinator.handleBackPress();
      coordinator.dispose();
      expect(coordinator.armed, isFalse);
      expect(coordinator.handleBackPress(), RootBackAction.showExitHint);
      coordinator.dispose();
    });

    test('lifecycle and route transitions disarm an armed root exit', () {
      final coordinator = RootBackCoordinator();
      coordinator.handleBackPress();
      coordinator.onLifecycleChange(AppLifecycleState.paused);
      expect(coordinator.armed, isFalse);

      coordinator.handleBackPress();
      coordinator.onRoutePushed();
      expect(coordinator.armed, isFalse);
      coordinator.dispose();
    });
  });
}
