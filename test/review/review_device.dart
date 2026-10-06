import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/platform/platform_caps.dart';

/// The user's device. The panel size is measured; density and system bar
/// insets are common values for a 1440p ROM until a probe report's
/// `surface:` line gives the real ones — change only these constants.
const reviewPhysicalSize = Size(1440, 3136);
const reviewDpr = 3.5;
const reviewStatusBar = 40.0;
const reviewNavigationBar = 16.0;

/// Where fonts, PNGs, films and the manifest land: `PARFAIT_REVIEW_OUT`,
/// else `~/parfait-ux4-review`. Outside the repo, so review output never
/// becomes a commit.
final reviewOutDir =
    Platform.environment['PARFAIT_REVIEW_OUT'] ??
    '${Platform.environment['HOME']}/parfait-ux4-review';

/// Applies the review device: panel size, density, system bar insets, the
/// [locale] as the system locale, font scale, system [brightness] (the
/// app's theme setting follows the system by default), and the engine's
/// `accessibleNavigation` stuck on — the state GKD leaves it in on the
/// user's phone — and Android as the platform, for the framework and for
/// the widgets that read [PlatformCaps.system]. Whether touch exploration
/// is on is a provider, set by `ReviewWorld.open`.
void applyReviewDevice(
  WidgetTester tester, {
  required Locale locale,
  double textScale = 1.0,
  Brightness brightness = Brightness.light,
}) {
  final view = tester.view;
  view.physicalSize = reviewPhysicalSize;
  view.devicePixelRatio = reviewDpr;
  const insets = FakeViewPadding(
    top: reviewStatusBar * reviewDpr,
    bottom: reviewNavigationBar * reviewDpr,
  );
  view.padding = insets;
  view.viewPadding = insets;
  final dispatcher = tester.platformDispatcher;
  dispatcher.localesTestValue = [locale];
  dispatcher.localeTestValue = locale;
  dispatcher.textScaleFactorTestValue = textScale;
  dispatcher.platformBrightnessTestValue = brightness;
  dispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
    accessibleNavigation: true,
  );
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  PlatformCaps.debugSystemOverride = const PlatformCaps(isAndroid: true);
}

void resetReviewDevice(WidgetTester tester) {
  final view = tester.view;
  view.resetPhysicalSize();
  view.resetDevicePixelRatio();
  view.resetPadding();
  view.resetViewPadding();
  view.resetViewInsets();
  final dispatcher = tester.platformDispatcher;
  dispatcher.clearLocalesTestValue();
  dispatcher.clearLocaleTestValue();
  dispatcher.clearTextScaleFactorTestValue();
  dispatcher.clearPlatformBrightnessTestValue();
  dispatcher.clearAccessibilityFeaturesTestValue();
  debugDefaultTargetPlatformOverride = null;
  PlatformCaps.debugSystemOverride = null;
}
