import 'package:flutter_test/flutter_test.dart';

// Waits shared by every test (TEST-10, TEST-11). Each one that waits for a
// condition fails when the condition never holds, so a case cannot pass on
// a wait that ran out.

/// Turns the event loop (microtasks, zero timers) until [condition] holds;
/// for plain `test`s on real async.
Future<void> turnUntil(bool Function() condition, {int turns = 500}) async {
  for (var turn = 0; !condition(); turn++) {
    if (turn == turns) fail('condition not met in $turns event-loop turns');
    await Future<void>.delayed(Duration.zero);
  }
}

/// Polls [condition] in real time: disk-backed work needs actual IO turns,
/// not just microtasks.
Future<void> pollUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Pumps frames of [step] until [condition] holds.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration step = const Duration(milliseconds: 20),
  int frames = 40,
}) async {
  for (var frame = 0; !condition(); frame++) {
    if (frame == frames) fail('condition not met in $frames frames');
    await tester.pump(step);
  }
}

/// Alternates [io] of real time, which work on real IO (files, an
/// in-process worker) needs to advance, with a frame of [step], until
/// [condition] holds.
Future<void> pumpIoUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration io = const Duration(milliseconds: 20),
  Duration step = Duration.zero,
  int rounds = 60,
}) async {
  for (var round = 0; !condition(); round++) {
    if (round == rounds) fail('condition not met in $rounds IO rounds');
    await tester.runAsync(() => Future<void>.delayed(io));
    await tester.pump(step);
  }
}
