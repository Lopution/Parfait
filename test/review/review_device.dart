import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/platform/platform_caps.dart';

/// A screen the review renders on: the panel in physical pixels, its
/// density, and the system bar and display cutout insets in logical
/// pixels (the cutout sits on the left, as on a phone turned left).
class ReviewDevice {
  const ReviewDevice({
    required this.physicalSize,
    required this.dpr,
    this.statusBar = 0,
    this.navigationBar = 0,
    this.cutout = 0,
  });

  final Size physicalSize;
  final double dpr;
  final double statusBar;
  final double navigationBar;
  final double cutout;
}

/// The screens `PARFAIT_REVIEW_DEVICE` names. `phone` is the user's
/// device and the default: the panel size is measured; density and insets
/// are common values for a 1440p ROM until a probe report's `surface:`
/// line gives the real ones. The others sit in the window classes the
/// layout switches on (logical sizes in the comments).
const reviewDevices = <String, ReviewDevice>{
  // 411 x 896.
  'phone': ReviewDevice(
    physicalSize: Size(1440, 3136),
    dpr: 3.5,
    statusBar: 40,
    navigationBar: 16,
  ),
  // 896 x 411, the camera cutout on the left.
  'phone-landscape': ReviewDevice(
    physicalSize: Size(3136, 1440),
    dpr: 3.5,
    statusBar: 40,
    navigationBar: 16,
    cutout: 40,
  ),
  // 700 x 840, a book-style foldable opened.
  'foldable': ReviewDevice(
    physicalSize: Size(1840, 2208),
    dpr: 2.625,
    statusBar: 32,
    navigationBar: 16,
  ),
  // 800 x 1280.
  'tablet-portrait': ReviewDevice(
    physicalSize: Size(1600, 2560),
    dpr: 2,
    statusBar: 24,
    navigationBar: 16,
  ),
  // 1000 x 640, an 8-inch tablet turned.
  'tablet-small-landscape': ReviewDevice(
    physicalSize: Size(2000, 1280),
    dpr: 2,
    statusBar: 24,
    navigationBar: 16,
  ),
  // 1280 x 800.
  'tablet-landscape': ReviewDevice(
    physicalSize: Size(2560, 1600),
    dpr: 2,
    statusBar: 24,
    navigationBar: 16,
  ),
  // 1440 x 900, a desktop window: no system bars.
  'desktop': ReviewDevice(physicalSize: Size(2880, 1800), dpr: 2),
};

/// The device of this run, from `PARFAIT_REVIEW_DEVICE` (default `phone`).
final reviewDeviceName =
    Platform.environment['PARFAIT_REVIEW_DEVICE'] ?? 'phone';
final ReviewDevice reviewDevice =
    reviewDevices[reviewDeviceName] ??
    (throw ArgumentError.value(
      reviewDeviceName,
      'PARFAIT_REVIEW_DEVICE',
      'one of ${reviewDevices.keys.join(', ')}',
    ));

/// Where fonts, PNGs, films and the manifest land: `PARFAIT_REVIEW_OUT`,
/// else `~/parfait-ux4-review`. Outside the repo, so review output never
/// becomes a commit.
final reviewOutDir =
    Platform.environment['PARFAIT_REVIEW_OUT'] ??
    '${Platform.environment['HOME']}/parfait-ux4-review';

/// Applies [device] (by default [reviewDevice]): panel size, density,
/// system bar insets, the [locale] as the system locale, font scale,
/// system [brightness] (the app's theme setting follows the system by
/// default), and the engine's `accessibleNavigation` stuck on — the state
/// GKD leaves it in on the user's phone — and Android as the platform, for
/// the framework and for the widgets that read [PlatformCaps.system].
/// Shadows render as on the device: flutter_test otherwise draws every
/// elevation as a solid black outline. Whether touch exploration is on is
/// a provider, set by `ReviewWorld.open`.
void applyReviewDevice(
  WidgetTester tester, {
  required Locale locale,
  double textScale = 1.0,
  Brightness brightness = Brightness.light,
  ReviewDevice? device,
}) {
  final view = tester.view;
  device ??= reviewDevice;
  // In a tear-down, not [resetReviewDevice]: a view change gives the render
  // view a new root layer, and one made in the test body outlives it.
  addTearDown(view.reset);
  view.physicalSize = device.physicalSize;
  view.devicePixelRatio = device.dpr;
  final insets = FakeViewPadding(
    left: device.cutout * device.dpr,
    top: device.statusBar * device.dpr,
    bottom: device.navigationBar * device.dpr,
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
  debugDisableShadows = false;
}

void resetReviewDevice(WidgetTester tester) {
  final dispatcher = tester.platformDispatcher;
  dispatcher.clearLocalesTestValue();
  dispatcher.clearLocaleTestValue();
  dispatcher.clearTextScaleFactorTestValue();
  dispatcher.clearPlatformBrightnessTestValue();
  dispatcher.clearAccessibilityFeaturesTestValue();
  debugDefaultTargetPlatformOverride = null;
  PlatformCaps.debugSystemOverride = null;
  // The flutter_test default the end-of-test invariant check expects.
  debugDisableShadows = true;
}
