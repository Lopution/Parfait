import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// Gives the test view an Android device's touch slop, [slop] logical
/// pixels, instead of the test default kTouchSlop. Call it after the view
/// size: the slop is set in physical pixels.
void setDeviceTouchSlop(WidgetTester tester, {double slop = 8}) {
  tester.view.gestureSettings = ui.GestureSettings(
    physicalTouchSlop: slop * tester.view.devicePixelRatio,
  );
  addTearDown(tester.view.resetGestureSettings);
}

/// Starts a drag at [origin] and moves it [distance] pixels leftwards and
/// upwards, [degrees] off the horizontal, in 1px steps: a finger's stream
/// of small moves rather than one jump past every slop. The gesture stays
/// down.
Future<TestGesture> dragLeftUp(
  WidgetTester tester,
  Offset origin, {
  required double degrees,
  int distance = 40,
}) async {
  final radians = degrees * math.pi / 180;
  final step = Offset(-math.cos(radians), -math.sin(radians));
  final gesture = await tester.startGesture(origin);
  for (var i = 0; i < distance; i++) {
    await gesture.moveBy(step);
  }
  await tester.pump();
  return gesture;
}
