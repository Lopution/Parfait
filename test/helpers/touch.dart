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
