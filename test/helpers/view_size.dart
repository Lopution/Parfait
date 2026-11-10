import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sets the test view to [size] logical pixels (device pixel ratio 1) and
/// restores the view when the test ends.
void setViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Sets the display the test view is on to [size] logical pixels and
/// restores it when the test ends. The view and its display share one pixel
/// ratio, so call this after [setViewSize]. The default display is 800×600,
/// which is not a phone (`AppBreakpoints.isPhoneDisplay`).
void setDisplaySize(WidgetTester tester, Size size) {
  final display = tester.view.display;
  display.size = size * display.devicePixelRatio;
  addTearDown(display.resetSize);
}
