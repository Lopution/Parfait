import 'dart:async';

import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/platform/native_warmup.dart';

void main() {
  testWidgets('each step waits for a short pause without frames', (
    tester,
  ) async {
    final calls = <int>[];
    final animation = AnimationController(
      vsync: tester,
      duration: const Duration(seconds: 2),
    )..forward();
    addTearDown(animation.dispose);

    unawaited(
      warmUpWhenQuiet([() async => calls.add(1), () async => calls.add(2)]),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(calls, isEmpty, reason: 'the animation kept drawing frames');

    // Let the animation finish; from its last frame on only fake time passes.
    await tester.pumpAndSettle();
    await tester.binding.delayed(const Duration(milliseconds: 450));
    expect(calls, [1]);
    await tester.binding.delayed(const Duration(milliseconds: 450));
    expect(calls, [1, 2]);
  });
}
